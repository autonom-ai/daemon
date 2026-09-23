// Team Room — the human's seat on the coord bus, as a Devin Desktop view.
//
// The extension host owns the bus (./bus.js): no HTTP server, no port, no
// browser, no respawn wrapper. The webview is presentation only — it renders
// what the host posts and sends back say/dm intents.
//
// The room opens as an editor tab (agentCoord.focus / agentCoord.openPanel).

const vscode = require("vscode");
const fs = require("node:fs");
const path = require("node:path");
const { openBus, readJson } = require("./bus.js");

const VIEW_ID = "agentCoord.chat";
const MEDIA_DIR = path.join(__dirname, "media");
const POLL_MS = 750;
const HEARTBEAT_MS = 30_000;
const RECONCILE_MS = 10_000;
const RETRY_MS = 3_000;
const RETRY_MAX_MS = 30_000;

let bus = null;
let busPromise = null;
let busError = null;
let workspace = null;
let view = null;
let panel = null;
let pollTimer = null;
let retryTimer = null;
let retryDelay = RETRY_MS;
let unreadPings = 0;
let lastHeartbeat = 0;
let lastReconcile = 0;

function findWorkspace()
{
    const configured = vscode.workspace.getConfiguration("agentCoord").get("workspace");
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
        ?? vscode.workspace.getConfiguration("agentCoord").get("coordRoot")
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
    if (busPromise)
        return busPromise;
    const projectDir = findWorkspace();
    if (!projectDir)
    {
        busError = "No .devin/coord.json in the open folders — this workspace is not wired into a team.";
        postAll({ type: "conn", up: false });
        postAll({ type: "toast", text: busError, tone: "bad" });
        scheduleReconnect();
        return null;
    }
    const coordRoot = coordRootOf(projectDir);
    if (!coordRoot)
    {
        busError = "coord.json has no coordRoot and agentCoord.coordRoot is not set.";
        postAll({ type: "toast", text: busError, tone: "bad" });
        scheduleReconnect();
        return null;
    }
    // One open, shared: the view and the first poll can both ask at once, and a
    // second openBus would move the pump's boundary past messages that arrived
    // while the first was still importing.
    busPromise = openBus({ projectDir, coordRoot })
        .then(async (opened) =>
        {
            bus = opened;
            workspace = projectDir;
            retryDelay = RETRY_MS;
            postAll({ type: "conn", up: true });
            await pushState();
            return bus;
        })
        .catch((err) =>
        {
            busError = err?.message ?? String(err);
            postAll({ type: "conn", up: false });
            postAll({ type: "toast", text: `team room: ${busError}`, tone: "bad" });
            scheduleReconnect();
            return null;
        });
    return busPromise;
}

// A failed open is not terminal. The store may not be built yet, coord.json may
// still be wrong, the workspace may still be opening — so back off and retry
// instead of leaving the room dead until the extension is unloaded. This is the
// recovery path the manual refresh used to be the only way to reach.
function scheduleReconnect()
{
    if (retryTimer)
        return;
    retryTimer = setTimeout(() =>
    {
        retryTimer = null;
        refresh();
    }, retryDelay);
    retryDelay = Math.min(retryDelay * 2, RETRY_MAX_MS);
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

// A manual refresh is the retry path: a failed bus open (missing store, a
// coord.json fix) clears here so the next attempt is real, not cached.
async function refresh()
{
    busError = null;
    busPromise = null;
    if (retryTimer)
    {
        clearTimeout(retryTimer);
        retryTimer = null;
    }
    if (!bus && !(await ensureBus()))
        return;
    await pushState();
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
                vscode.commands.executeCommand("agentCoord.focus");
        });
}

async function poll()
{
    if (!bus && !(await ensureBus()))
        return;
    try
    {
        const fresh = bus.pump();
        // One post for the whole batch: a burst used to mean one full re-render
        // of the log per entry, which is where the room got sluggish.
        if (fresh.length)
            postAll({ type: "messages", entries: fresh });
        for (const entry of fresh)
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
        // The incremental stream can miss a line — a compaction reset, a write
        // that lands between reads, a webview that reloaded mid-burst. A slow
        // full-state push while the room is on screen makes the view converge
        // on its own instead of waiting for a manual refresh.
        if (visible() && Date.now() - lastReconcile > RECONCILE_MS)
        {
            lastReconcile = Date.now();
            await pushState();
        }
        if (Date.now() - lastHeartbeat > HEARTBEAT_MS)
        {
            lastHeartbeat = Date.now();
            await bus.heartbeat();
        }
    }
    catch (err)
    {
        // Drop the bus so the retry reopens it from scratch rather than
        // pumping through offsets that just failed.
        bus = null;
        busError = err?.message ?? String(err);
        postAll({ type: "conn", up: false });
        postAll({ type: "toast", text: `team room: ${busError}`, tone: "bad" });
        scheduleReconnect();
    }
}

async function handleMessage(message)
{
    if (!bus && !(await ensureBus()))
        return;
    try
    {
        if (message.type === "ready")
        {
            await pushState();
            return;
        }
        if (message.type === "refresh")
        {
            await refresh();
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
    panel = vscode.window.createWebviewPanel("agentCoord.panel", "Team Room", vscode.ViewColumn.Active, { retainContextWhenHidden: true });
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
        vscode.commands.registerCommand("agentCoord.focus", openPanel),
        vscode.commands.registerCommand("agentCoord.openPanel", openPanel),
        vscode.commands.registerCommand("agentCoord.refresh", refresh),
    );

    const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 90);
    status.text = "$(comment-discussion) team room";
    status.tooltip = "Open the team room";
    status.command = "agentCoord.focus";
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
    if (retryTimer)
        clearTimeout(retryTimer);
}

module.exports = { activate, deactivate };
