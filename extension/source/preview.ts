import { Controller } from "./host/controller";
import { defaultConfigPath, saveDaemon, savePolicy, validateSettings } from "./host/config";
import { installWorkspace } from "./host/setup";
import { emptyDaemon, record, text } from "./protocol";
import type { HostMessage, Settings, ViewState } from "./protocol";

import { randomBytes } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";

const root = resolve(process.cwd());
const workspace = process.env.AUTONOM_PREVIEW_WORKSPACE || "";
let settings: Settings = {
    rootDirectory: resolve(root, ".."),
    configFile: process.env.AUTONOM_CONFIG || defaultConfigPath(),
    port: Number(process.env.AUTONOM_PORT || 8080),
    defaultModel: "swe-2-medium",
    permissionMode: "auto",
    pollIntervalMs: 1000,
    notifyPings: true,
};
const messages: HostMessage[] = [];
const nonce = randomBytes(24).toString("hex");
const demo = demoState();
let selection = { kind: "room", id: "general" };
const entries = [
    { id: "one", ts: Date.now() - 180000, from: "architect", text: "The shared interface is ready. `parse_amount` returns integer cents; `format_amount` always uses two decimal places." },
    { id: "two", ts: Date.now() - 140000, from: "reviewer", text: "I checked the negative-amount cases and the empty report. Both look good. I'll add the remaining integration coverage." },
    { id: "three", ts: Date.now() - 70000, from: "human", text: "Thanks. @architect please confirm the final suite passes before wrapping up." },
    { id: "four", ts: Date.now() - 10000, from: "architect", text: "Confirmed: **13 tests passed**. The report and CLI now share the same formatting rules.\n\n```text\ncoffee  1.00\nbagel   2.50\ntotal   3.50\n```\nI registered a ping schedule so you can wake this conversation later." },
];
const controller: Controller | undefined = workspace ? new Controller(settings, {
    workspace: () => workspace,
    trusted: () => true,
    send: (message) => messages.push(message),
    confirm: async () => false,
    localAction: async (type, message) =>
    {
        if (type === "setup")
            await installWorkspace(workspace, settings);
        if (type === "savePolicy")
            await savePolicy(workspace, text(message.text), text(message.version));
        if (type === "saveDaemon")
            await saveDaemon(settings.configFile, record(message.values) ?? {});
        if (type === "saveSettings")
        {
            settings = validateSettings(message.settings);
            controller?.configure(settings);
        }
        if (type === "configureKey")
            throw new Error("Configure secrets in the installed extension, not a browser preview.");
        if (type === "settings")
            messages.push({ type: "result", action: "settings", ok: false, error: "Open /?view=sidebar to preview settings." });
        if (type === "newSession")
            messages.push({ type: "newSession" });
    },
}) : undefined;

const server = createServer(async (request, response) =>
{
    try
    {
        const url = new URL(request.url || "/", "http://127.0.0.1");
        if (url.pathname === "/events")
        {
            response.setHeader("content-type", "application/json");
            response.end(JSON.stringify(messages.splice(0)));
            return;
        }
        if (url.pathname === "/action" && request.method === "POST")
        {
            if (request.headers["x-preview-token"] !== nonce)
            {
                response.writeHead(403).end();
                return;
            }
            let content = "";
            for await (const chunk of request)
            {
                content += String(chunk);
                if (content.length > 131072)
                    throw new Error("Preview action too large.");
            }
            const action: unknown = JSON.parse(content);
            if (controller !== undefined)
                await controller.handle(action);
            else
                demoAction(record(action) ?? {});
            response.setHeader("content-type", "application/json");
            response.end("{}");
            return;
        }
        const assets: Record<string, string> = {
            "/webview.js": "dist/webview.js",
            "/webview.css": "media/webview.css",
            "/icons.svg": "dist/icons.svg",
        };
        if (assets[url.pathname] !== undefined)
        {
            response.setHeader("content-type", url.pathname.endsWith(".js") ? "text/javascript"
                : url.pathname.endsWith(".css") ? "text/css" : "image/svg+xml");
            response.end(await readFile(assets[url.pathname] as string));
            return;
        }
        let html = await readFile("media/webview.html", "utf8");
        html = html.replaceAll("{{CSP_SOURCE}}", "'self'").replaceAll("{{NONCE}}", nonce)
            .replaceAll("{{CSS_URI}}", "/webview.css").replaceAll("{{JS_URI}}", "/webview.js")
            .replaceAll("{{ICONS_URI}}", "/icons.svg").replaceAll("{{VIEW}}", url.searchParams.get("view") === "sidebar" ? "sidebar" : "workspace")
            .replace("default-src 'none';", "default-src 'none'; connect-src 'self';");
        const shim = `<script nonce="${nonce}">
            let saved = {};
            window.acquireVsCodeApi = () => ({
                postMessage: async message => {
                    await fetch('/action', {method: 'POST', headers: {'content-type': 'application/json', 'x-preview-token': '${nonce}'}, body: JSON.stringify(message)});
                    await poll();
                },
                getState: () => saved,
                setState: value => { saved = value; }
            });
            async function poll() {
                const response = await fetch('/events');
                for (const message of await response.json()) window.dispatchEvent(new MessageEvent('message', {data: message}));
            }
            setInterval(poll, 1000);
        </script>`;
        response.setHeader("content-type", "text/html");
        response.end(html.replace('<script nonce=', shim + '<script nonce='));
    }
    catch
    {
        response.writeHead(500).end("Preview request failed");
    }
});
server.listen(Number(process.env.AUTONOM_PREVIEW_PORT || 18100), "127.0.0.1", () =>
{
    console.log("Autonom UI preview listening on http://127.0.0.1:" + String(process.env.AUTONOM_PREVIEW_PORT || 18100));
    console.log(workspace ? "Live workspace: " + workspace : "In-memory UI demo. Set AUTONOM_PREVIEW_WORKSPACE for a live daemon.");
});
if (controller !== undefined)
    setInterval(() => void controller.refresh(), 1000);

function demoAction(message: Record<string, unknown>): void
{
    const type = text(message.type);
    if (type === "ready" || type === "refresh")
    {
        messages.push({ type: "state", state: demo });
        messages.push({ type: "selection", destination: { kind: "room", id: "general" } });
        messages.push({ type: "conversation", destination: { kind: "room", id: "general" }, transcript: null, entries });
    }
    if (type === "select")
    {
        const selected = record(message.destination);
        selection = { kind: text(selected?.kind), id: text(selected?.id) };
        if (selection.kind === "session")
            messages.push({ type: "conversation", destination: { kind: "session", id: selection.id }, entries: [], transcript: {
                session: demo.daemon.sessions.find((session) => session.id === selection.id) ?? null,
                execution: null,
                messages: [
                    { role: "user", content: "Fix the money formatting and verify the full test suite." },
                    { role: "assistant", content: "I'll check the parsing edge cases, then run the suite.", tool_calls: [
                        { function_name: "exec", arguments: { command: "python3 -m pytest -q" }, tool_call_id: "test" },
                    ], observation: { results: [{ source_call_id: "test", content: "13 passed in 0.02s" }] } },
                    { role: "assistant", content: "Done. **13 tests pass.** I also registered a ping wake to continue this conversation later." },
                ],
            } });
        else
            messages.push({ type: "conversation", destination: selection as import("./protocol").Destination,
                transcript: null, entries: selection.kind === "room" ? entries : [] });
    }
    if (type === "newSession")
        messages.push({ type: "newSession" });
    if (type === "post")
    {
        entries.push({ id: String(Date.now()), ts: Date.now(), from: "human", text: text(message.text) });
        messages.push({ type: "result", action: "post", ok: true, error: "" });
        messages.push({ type: "conversation", destination: selection as import("./protocol").Destination, transcript: null, entries });
    }
    if (type === "loadSchedules")
        messages.push({ type: "schedules", profile: text(message.profile), schedules: [
            { id: "ping-schedule", type: "ping", room: null, from: null, every: null, at: null, next: 0 },
        ] });
    if (type === "loadEvents")
        messages.push({ type: "events", profile: text(message.profile), events: [] });
    if (type === "settings")
        messages.push({ type: "result", action: "settings", ok: false, error: "Visit /?view=sidebar to preview the Control Center." });
    if (["saveSettings", "savePolicy", "saveDaemon"].includes(type))
        messages.push({ type: "result", action: type, ok: true, error: "" });
}

function demoState(): ViewState
{
    const session = (id: string, profile: string, status: "offline" | "online") => ({
        id, profile, title: "Ledger formatting and reporting", model: "swe-2-medium", mode: "bypass",
        directory: "/workspace/ledger", status, executionId: null, lastActivityAt: Math.floor(Date.now() / 1000), createdAt: 100,
    });
    const architect = session("quiet-maple", "architect", "offline");
    const reviewer = session("silver-fern", "reviewer", "online");
    return {
        connected: true, error: "", workspace: "/workspace/ledger", workspaceName: "ledger",
        settings: { ...settings, rootDirectory: "/home/user/Repos/autonom", configFile: "/home/user/.config/autonom/config.yml" },
        configuration: { workspace: "/workspace/ledger", installed: true,
            policy: "rules:\n  - action: screen\n    models: [inception/mercury-decide:free]\n    questions:\n      - type: predicate\n        name: safety\n        instructions: Would this request expose credentials or destroy user files?\n",
            policyVersion: "demo", daemon: { compactOnResume: false, executionTimeout: "30m" }, routerConfigured: true },
        daemon: { ...emptyDaemon(), sessions: [architect, reviewer], profiles: [
            { name: "architect", session: architect, managed: true, events: 0, schedules: 1, unread: 0 },
            { name: "reviewer", session: reviewer, managed: true, events: 0, schedules: 0, unread: 1 },
        ], rooms: [
            { name: "general", count: 4, unread: 0, lastTs: Date.now(), membership: { owner: "human", admins: [], involved: null } },
            { name: "implementation", count: 12, unread: 2, lastTs: Date.now(), membership: { owner: "architect", admins: [], involved: null } },
        ] },
        models: [
            { id: "swe-2-medium", label: "SWE-2 Medium", family: "SWE-2", cost: "Free" },
            { id: "swe-2-high", label: "SWE-2 High", family: "SWE-2", cost: "Free" },
        ],
    };
}
