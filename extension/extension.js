// Team Room — the human's seat on the coord bus, as a Devin Desktop view.
//
// The extension host owns the bus (./bus.js): no HTTP server, no port, no
// browser, no respawn wrapper. The webview is presentation only — it renders
// what the host posts and sends back say/dm/recess/stand-down intents.
//
// The view is the room; the same UI opens as an editor panel for a wide
// layout (coordRoom.openPanel).

const vscode = require("vscode");
const fs = require("node:fs");
const path = require("node:path");
const { openBus, readJson } = require("./bus.js");

const VIEW_ID = "coordRoom.chat";
const MEDIA_DIR = path.join(__dirname, "media");
const POLL_MS = 750;
const HEARTBEAT_MS = 30_000;

let bus = null;
let busError = null;
let workspace = null;
let view = null;
let panel = null;
let pollTimer = null;
let unreadPings = 0;
let lastHeartbeat = 0;

function findWorkspace()
{
    const configured = vscode.workspace.getConfiguration("coordRoom").get("workspace");
    const folders = (vscode.workspace.workspaceFolders ?? []).map((folder) => folder.uri.fsPath);
    for (const dir of [...(configured ? [configured] : []), ...folders])
        if (dir && fs.existsSync(path.join(dir, ".devin", "coord.json")))
            return dir;
    return null;
}

function coordRootOf(projectDir)
{
    const config = readJson(path.join(projectDir, ".devin", "coord.json"), {});
    return config.coordRoot
        ?? vscode.workspace.getConfiguration("coordRoom").get("coordRoot")
        ?? null;
}

function webviews()
{
    return [view?.webview, panel?.webview].filter(Boolean);
}

function postAll(message)
{
    for (const webview of webviews())
        try
        {
            webview.postMessage(message);
        }
        catch { }
}

function visible()
{
    return Boolean(view?.visible || panel?.visible);
}

function updateBadge()
{
    if (!view)
        return;
    view.badge = unreadPings > 0
        ? { value: unreadPings, tooltip: `${unreadPings} ping${unreadPings === 1 ? "" : "s"} waiting` }
        : undefined;
}

async function ensureBus()
{
    if (bus || busError)
        return bus;
    const projectDir = findWorkspace();
    if (!projectDir)
    {
        busError = "No .devin/coord.json in the open folders — this workspace is not wired into a team.";
        postAll({ type: "conn", up: false });
        postAll({ type: "toast", text: busError, tone: "bad" });
        return null;
    }
    const coordRoot = coordRootOf(projectDir);
    if (!coordRoot)
    {
        busError = "coord.json has no coordRoot and coordRoom.coordRoot is not set.";
        postAll({ type: "toast", text: busError, tone: "bad" });
        return null;
    }
    try
    {
        bus = await openBus({ projectDir, coordRoot });
        workspace = projectDir;
        postAll({ type: "conn", up: true });
        await pushState();
    }
    catch (err)
    {
        busError = err?.message ?? String(err);
        postAll({ type: "conn", up: false });
        postAll({ type: "toast", text: `team room: ${busError}`, tone: "bad" });
    }
    return bus;
}

async function statePayload()
{
    const payload = await bus.state();
    return { ...payload, build: require("./package.json").version };
}

async function pushState()
{
    if (!bus)
        return;
    try
    {
        postAll({ type: "state", ...await statePayload() });
    }
    catch (err)
    {
        postAll({ type: "conn", up: false });
        postAll({ type: "toast", text: `team room: ${err?.message ?? err}`, tone: "bad" });
    }
}

// The room's own ping semantics, for the badge and the notification: a room
// line that names the human or @everyone.
function mentionsHuman(entry)
{
    if (entry.stream !== "room" || !entry.from || entry.from === bus.ctx.human)
        return false;
    const me = bus.ctx.human.toLowerCase();
    for (const match of (entry.text ?? "").matchAll(/@([A-Za-z0-9_-]+)/g))
    {
        const name = match[1].toLowerCase();
        if (name === me || name === "everyone" || name === "all")
            return true;
    }
    return false;
}

function notifyPing(entry)
{
    const preview = (entry.text ?? "").length > 140 ? `${entry.text.slice(0, 140)}…` : entry.text;
    vscode.window.showInformationMessage(`${entry.from} in #${entry.room}: ${preview}`, "Open Team Room")
        .then((choice) =>
        {
            if (choice === "Open Team Room")
                vscode.commands.executeCommand("coordRoom.focus");
        });
}

async function poll()
{
    if (!bus && !(await ensureBus()))
        return;
    try
    {
        const fresh = bus.pump();
        for (const entry of fresh)
        {
            postAll({ type: "message", entry });
            if (mentionsHuman(entry))
            {
                if (visible())
                {
                    unreadPings = 0;
                    updateBadge();
                }
                else
                {
                    unreadPings++;
                    updateBadge();
                    notifyPing(entry);
                }
            }
        }
        if (Date.now() - lastHeartbeat > HEARTBEAT_MS)
        {
            lastHeartbeat = Date.now();
            await bus.heartbeat();
        }
    }
    catch (err)
    {
        postAll({ type: "conn", up: false });
        postAll({ type: "toast", text: `team room: ${err?.message ?? err}`, tone: "bad" });
    }
}

async function handleMessage(message)
{
    if (!bus && !(await ensureBus()))
        return;
    try
    {
        if (message.type === "ready" || message.type === "refresh")
        {
            await pushState();
            return;
        }
        if (message.type === "say")
        {
            const { pinged } = await bus.say(message.room, String(message.text ?? "").trim(), message.kind);
            postAll({ type: "sent", ok: true, pinged });
            return;
        }
        if (message.type === "dm")
        {
            await bus.sendDm(message.to, String(message.text ?? "").trim());
            postAll({ type: "sent", ok: true, pinged: [message.to] });
            return;
        }
        if (message.type === "recess")
        {
            const result = await bus.recess(message.action, String(message.note ?? "").trim());
            if (!result.ok)
                postAll({ type: "toast", text: `recess: ${result.error}`, tone: "bad" });
            else
                postAll({
                    type: "toast",
                    text: message.action === "end"
                        ? "recess closed — the outcome is in #general"
                        : "recess open — every seat has been asked to stop and talk; workspace edits are blocked",
                    tone: "good",
                });
            await pushState();
            return;
        }
        if (message.type === "standdown")
        {
            const active = await bus.setStandDown(Boolean(message.active));
            postAll({ type: "docs", ...await statePayload(), standDown: active });
            return;
        }
        if (message.type === "openLink")
        {
            vscode.env.openExternal(vscode.Uri.parse(message.href));
            return;
        }
    }
    catch (err)
    {
        postAll({ type: "sent", ok: false, error: err?.message ?? String(err) });
    }
}

function htmlFor(webview)
{
    const nonce = Math.random().toString(36).slice(2) + Date.now().toString(36);
    const uri = (file) => webview.asWebviewUri(vscode.Uri.file(path.join(MEDIA_DIR, file)));
    return fs.readFileSync(path.join(MEDIA_DIR, "webview.html"), "utf8")
        .replaceAll("{{CSP_SOURCE}}", webview.cspSource)
        .replaceAll("{{NONCE}}", nonce)
        .replaceAll("{{CSS_URI}}", String(uri("webview.css")))
        .replaceAll("{{JS_URI}}", String(uri("webview.js")));
}

function wire(webview)
{
    webview.options = { enableScripts: true, localResourceRoots: [vscode.Uri.file(MEDIA_DIR)] };
    webview.html = htmlFor(webview);
    webview.onDidReceiveMessage((message) => handleMessage(message));
}

class RoomViewProvider
{
    resolveWebviewView(webviewView)
    {
        view = webviewView;
        wire(webviewView.webview);
        webviewView.onDidChangeVisibility(() =>
        {
            if (webviewView.visible)
            {
                unreadPings = 0;
                updateBadge();
                pushState();
            }
        });
        ensureBus();
    }
}

function openPanel()
{
    if (panel)
    {
        panel.reveal();
        return;
    }
    panel = vscode.window.createWebviewPanel("coordRoom.panel", "Team Room", vscode.ViewColumn.Active, { retainContextWhenHidden: true });
    panel.iconPath = vscode.Uri.file(path.join(MEDIA_DIR, "room.svg"));
    panel.onDidDispose(() => { panel = null; });
    panel.onDidChangeViewState(() =>
    {
        if (panel?.visible)
        {
            unreadPings = 0;
            updateBadge();
            pushState();
        }
    });
    wire(panel.webview);
    ensureBus();
}

function activate(context)
{
    context.subscriptions.push(
        vscode.window.registerWebviewViewProvider(VIEW_ID, new RoomViewProvider(), { webviewOptions: { retainContextWhenHidden: true } }),
        vscode.commands.registerCommand("coordRoom.focus", () => vscode.commands.executeCommand(`${VIEW_ID}.focus`)),
        vscode.commands.registerCommand("coordRoom.openPanel", openPanel),
        vscode.commands.registerCommand("coordRoom.refresh", pushState),
        vscode.commands.registerCommand("coordRoom.recess", () => handleMessage({ type: "recess", action: "start", note: "" })),
        vscode.commands.registerCommand("coordRoom.recessEnd", () => handleMessage({ type: "recess", action: "end", note: "" })),
        vscode.commands.registerCommand("coordRoom.standDown", () => handleMessage({ type: "standdown", active: true })),
        vscode.commands.registerCommand("coordRoom.resume", () => handleMessage({ type: "standdown", active: false })),
    );

    const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 90);
    status.text = "$(comment-discussion) team room";
    status.tooltip = "Open the team room";
    status.command = "coordRoom.focus";
    status.show();
    context.subscriptions.push(status);

    pollTimer = setInterval(poll, POLL_MS);
    context.subscriptions.push({ dispose: () => clearInterval(pollTimer) });
    poll();
}

function deactivate()
{
    if (pollTimer)
        clearInterval(pollTimer);
}

module.exports = { activate, deactivate };
