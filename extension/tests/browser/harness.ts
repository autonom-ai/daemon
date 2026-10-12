import { test as base, expect } from "@playwright/test";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { readFile } from "node:fs/promises";
import * as path from "node:path";
import { randomBytes } from "node:crypto";

import type {
    Destination,
    Entry,
    HostAction,
    HostMessage,
    Profile,
    Room,
    Schedule,
    Session,
    Transcript,
    ViewState,
    Event,
    PendingPermission,
} from "../../source/protocol.js";

const extensionRoot = path.resolve(__dirname, "../..");

export function createDefaultState(): ViewState {
    const session1: Session = {
        id: "session-1",
        title: "Architecture and refactor",
        model: "swe-2-medium",
        mode: "auto",
        directory: "/workspace/autonom",
        status: "online",
        executionId: null,
        lastActivityAt: Math.floor(Date.now() / 1000),
        createdAt: 1000,
        profile: "architect",
    };
    const session2: Session = {
        id: "session-2",
        title: "Code review agent",
        model: "swe-2-medium",
        mode: "auto",
        directory: "/workspace/autonom",
        status: "offline",
        executionId: null,
        lastActivityAt: Math.floor(Date.now() / 1000),
        createdAt: 2000,
        profile: "reviewer",
    };

    const architectProfile: Profile = {
        name: "architect",
        session: session1,
        managed: true,
        events: 0,
        schedules: 1,
        unread: 0,
    };
    const reviewerProfile: Profile = {
        name: "reviewer",
        session: session2,
        managed: true,
        events: 0,
        schedules: 0,
        unread: 1,
    };

    const generalRoom: Room = {
        name: "general",
        count: 2,
        unread: 0,
        lastTs: Date.now(),
        membership: { owner: "human", admins: [], involved: null },
    };
    const devRoom: Room = {
        name: "dev",
        count: 1,
        unread: 1,
        lastTs: Date.now(),
        membership: { owner: "architect", admins: ["reviewer"], involved: ["architect", "reviewer"] },
    };

    return {
        connected: true,
        error: "",
        workspace: "/workspace/autonom",
        workspaceName: "autonom",
        settings: {
            rootDirectory: "/home/cet/Repos/autonom",
            configFile: "/home/cet/Repos/autonom/templates/config.yml",
            port: 8080,
            defaultModel: "swe-2-medium",
            permissionMode: "auto",
            pollIntervalMs: 1000,
            notifyPings: true,
        },
        configuration: {
            workspace: "/workspace/autonom",
            installed: true,
            policy: "rules:\n  - action: screen\n    models: [inception/mercury-decide:free]\n",
            policyVersion: "1.0",
            daemon: { compactOnResume: false, executionTimeout: "30m" },
            routerConfigured: true,
        },
        daemon: {
            profiles: [architectProfile, reviewerProfile],
            sessions: [session1, session2],
            runs: [],
            rooms: [generalRoom, devRoom],
            permissions: [],
            humanEvents: 1,
        },
        models: [
            { id: "swe-2-medium", label: "SWE-2 Medium", family: "SWE-2", cost: "Free" },
            { id: "swe-2-high", label: "SWE-2 High", family: "SWE-2", cost: "Free" },
        ],
    };
}

export class TestHarness {
    public server: Server | null = null;
    public port = 0;
    public baseUrl = "";
    public nonce = "";
    public state: ViewState = createDefaultState();
    public selected: Destination = { kind: "room", id: "general" };
    public entries = new Map<string, Entry[]>();
    public transcripts = new Map<string, Transcript>();
    public schedules = new Map<string, Schedule[]>();
    public events = new Map<string, Event[]>();
    public capturedActions: HostAction[] = [];
    public queuedMessages: HostMessage[] = [];

    private actionWaiters: Array<{
        predicate: (action: HostAction) => boolean;
        resolve: (action: HostAction) => void;
    }> = [];
    private nextResults = new Map<string, { ok: boolean; error: string }>();

    constructor() {
        this.resetState();
    }

    public resetState(): void {
        this.state = createDefaultState();
        this.selected = { kind: "room", id: "general" };
        this.entries.clear();
        this.transcripts.clear();
        this.schedules.clear();
        this.events.clear();
        this.capturedActions = [];
        this.queuedMessages = [];
        this.actionWaiters = [];
        this.nextResults.clear();

        this.entries.set("room:general", [
            {
                id: "msg-gen-1",
                ts: Date.now() - 60000,
                from: "architect",
                text: "Welcome to the team room! Ready for collaboration.",
                room: "general",
            },
            {
                id: "msg-gen-2",
                ts: Date.now() - 30000,
                from: "reviewer",
                text: "Looking forward to working together.",
                room: "general",
            },
        ]);

        this.entries.set("room:dev", [
            {
                id: "msg-dev-1",
                ts: Date.now() - 10000,
                from: "architect",
                text: "Implementation branch is ready for review.",
                room: "dev",
            },
        ]);

        this.entries.set("dm:architect", [
            {
                id: "dm-arch-1",
                ts: Date.now() - 50000,
                from: "architect",
                text: "Direct message: Please check the blueprint.",
                to: "human",
            },
        ]);

        this.entries.set("dm:reviewer", [
            {
                id: "dm-rev-1",
                ts: Date.now() - 40000,
                from: "reviewer",
                text: "Review notes are uploaded.",
                to: "human",
            },
        ]);

        this.entries.set("pings:human", [
            {
                id: "ping-1",
                ts: Date.now() - 20000,
                from: "architect",
                text: "@human Need confirmation on architecture decision.",
                to: "human",
            },
        ]);

        this.transcripts.set("session:session-1", {
            session: this.state.daemon.sessions[0] ?? null,
            execution: null,
            messages: [
                {
                    role: "user",
                    content: "Inspect the repo and run the test suite.",
                    timestamp: Date.now() - 100000,
                },
                {
                    role: "assistant",
                    content: "I'll start by checking the files, then run pytest.",
                    reasoning_content: "Analyzing workspace tools and running test execution.",
                    tool_calls: [
                        {
                            tool_call_id: "call-exec-1",
                            function_name: "exec",
                            arguments: { command: "python3 -m pytest -q" },
                        },
                        {
                            tool_call_id: "call-mcp-1",
                            function_name: "mcp__autonom-coord__read_events",
                            arguments: { limit: 5 },
                        },
                    ],
                    observation: {
                        results: [
                            {
                                source_call_id: "call-exec-1",
                                content: "12 passed in 0.04s",
                            },
                            {
                                source_call_id: "call-mcp-1",
                                content: "[]",
                            },
                        ],
                    },
                    timestamp: Date.now() - 80000,
                },
                {
                    role: "assistant",
                    content: "All tests passed cleanly.",
                    timestamp: Date.now() - 70000,
                },
            ],
        });

        this.schedules.set("architect", [
            {
                id: "sched-1",
                type: "ping",
                room: null,
                from: null,
                every: null,
                at: null,
                next: 0,
            },
        ]);

        this.events.set("architect", [
            {
                id: "evt-1",
                type: "ping",
                text: "Ping from human",
                from: "human",
                room: null,
                ts: Date.now() - 15000,
            },
        ]);
    }

    public async start(): Promise<void> {
        this.nonce = randomBytes(16).toString("hex");

        this.server = createServer(async (request, response) => {
            try {
                const url = new URL(request.url ?? "/", `http://127.0.0.1:${this.port}`);

                if (url.pathname === "/events") {
                    response.setHeader("content-type", "application/json");
                    const messages = this.queuedMessages.splice(0);
                    response.end(JSON.stringify(messages));
                    return;
                }

                if (url.pathname === "/action" && request.method === "POST") {
                    if (request.headers["x-preview-token"] !== this.nonce) {
                        response.writeHead(403).end("Forbidden");
                        return;
                    }
                    let content = "";
                    for await (const chunk of request) {
                        content += String(chunk);
                    }
                    const action = JSON.parse(content) as HostAction;
                    this.handleAction(action);
                    response.setHeader("content-type", "application/json");
                    response.end("{}");
                    return;
                }

                if (url.pathname === "/webview.js") {
                    response.setHeader("content-type", "text/javascript");
                    const file = await readFile(path.join(extensionRoot, "dist/webview.js"));
                    response.end(file);
                    return;
                }

                if (url.pathname === "/webview.css") {
                    response.setHeader("content-type", "text/css");
                    const file = await readFile(path.join(extensionRoot, "media/webview.css"));
                    response.end(file);
                    return;
                }

                if (url.pathname === "/icons.svg") {
                    response.setHeader("content-type", "image/svg+xml");
                    const file = await readFile(path.join(extensionRoot, "dist/icons.svg"));
                    response.end(file);
                    return;
                }

                const view = url.searchParams.get("view") === "sidebar" ? "sidebar" : "workspace";
                let html = await readFile(path.join(extensionRoot, "media/webview.html"), "utf8");
                html = html
                    .replaceAll("{{CSP_SOURCE}}", "'self'")
                    .replaceAll("{{NONCE}}", this.nonce)
                    .replaceAll("{{CSS_URI}}", "/webview.css")
                    .replaceAll("{{JS_URI}}", "/webview.js")
                    .replaceAll("{{ICONS_URI}}", "/icons.svg")
                    .replaceAll("{{VIEW}}", view)
                    .replace("default-src 'none';", "default-src 'none'; connect-src 'self';");

                const shim = `<script nonce="${this.nonce}">
                    let saved = {};
                    window.acquireVsCodeApi = () => ({
                        postMessage: async message => {
                            try {
                                await fetch('/action', {
                                    method: 'POST',
                                    headers: {
                                        'content-type': 'application/json',
                                        'x-preview-token': '${this.nonce}'
                                    },
                                    body: JSON.stringify(message)
                                });
                                await poll();
                            } catch (e) {
                                console.error('Harness postMessage error', e);
                            }
                        },
                        getState: () => saved,
                        setState: value => { saved = value; }
                    });
                    async function poll() {
                        try {
                            const res = await fetch('/events');
                            if (!res.ok) return;
                            const msgs = await res.json();
                            for (const m of msgs) {
                                window.dispatchEvent(new MessageEvent('message', { data: m }));
                            }
                        } catch (e) {}
                    }
                    setInterval(poll, 30);
                </script>`;

                html = html.replace("<script nonce=", shim + "<script nonce=");
                response.setHeader("content-type", "text/html");
                response.end(html);
            } catch (error) {
                response.writeHead(500).end("Harness request failed: " + String(error));
            }
        });

        await new Promise<void>((resolve) => {
            this.server?.listen(0, "127.0.0.1", () => {
                const addr = this.server?.address() as AddressInfo;
                this.port = addr.port;
                this.baseUrl = `http://127.0.0.1:${this.port}`;
                resolve();
            });
        });
    }

    public async stop(): Promise<void> {
        if (this.server) {
            this.server.closeAllConnections?.();
            await new Promise<void>((resolve) => {
                this.server?.close(() => resolve());
            });
            this.server = null;
        }
    }

    public pushMessage(message: HostMessage): void {
        this.queuedMessages.push(message);
    }

    public pushMessages(...messages: HostMessage[]): void {
        this.queuedMessages.push(...messages);
    }

    public setNextActionResult(actionType: string, ok: boolean, error = ""): void {
        this.nextResults.set(actionType, { ok, error });
    }

    public getEntries(destination: Destination): Entry[] {
        const key = `${destination.kind}:${destination.id}`;
        return this.entries.get(key) ?? [];
    }

    public getTranscript(destination: Destination): Transcript | null {
        if (destination.kind === "session") {
            return this.transcripts.get(`session:${destination.id}`) ?? null;
        }
        return null;
    }

    public addIncomingEntry(dest: Destination, entry: Entry): void {
        const key = `${dest.kind}:${dest.id}`;
        const list = this.entries.get(key) ?? [];
        list.push(entry);
        this.entries.set(key, list);

        if (dest.kind === "room") {
            const room = this.state.daemon.rooms.find((r) => r.name === dest.id);
            if (room) {
                room.count++;
                room.lastTs = entry.ts;
                if (this.selected.kind !== "room" || this.selected.id !== dest.id) {
                    room.unread++;
                }
            }
        }

        if (this.selected.kind === dest.kind && this.selected.id === dest.id) {
            this.pushMessage({
                type: "conversation",
                destination: dest,
                transcript: null,
                entries: list,
            });
        }
        this.pushMessage({ type: "state", state: this.state });
    }

    public addPermission(permission: PendingPermission): void {
        this.state.daemon.permissions.push(permission);
        this.pushMessage({ type: "state", state: this.state });
    }

    public waitForAction(
        predicate: (action: HostAction) => boolean,
        timeout = 5000,
    ): Promise<HostAction> {
        const found = this.capturedActions.find(predicate);
        if (found) {
            return Promise.resolve(found);
        }
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                const idx = this.actionWaiters.findIndex((w) => w.resolve === resolve);
                if (idx !== -1) {
                    this.actionWaiters.splice(idx, 1);
                }
                reject(new Error(`Timed out after ${timeout}ms waiting for action`));
            }, timeout);

            this.actionWaiters.push({
                predicate,
                resolve: (action) => {
                    clearTimeout(timer);
                    resolve(action);
                },
            });
        });
    }

    private handleAction(action: HostAction): void {
        this.capturedActions.push(action);

        for (let i = this.actionWaiters.length - 1; i >= 0; i--) {
            const waiter = this.actionWaiters[i];
            if (waiter && waiter.predicate(action)) {
                this.actionWaiters.splice(i, 1);
                waiter.resolve(action);
            }
        }

        const override = this.nextResults.get(action.type);
        if (override) {
            this.nextResults.delete(action.type);
            this.pushMessage({
                type: "result",
                action: action.type,
                ok: override.ok,
                error: override.error,
            });
            if (!override.ok) {
                return;
            }
        }

        switch (action.type) {
            case "ready":
            case "refresh": {
                this.pushMessage({ type: "state", state: this.state });
                this.pushMessage({ type: "selection", destination: this.selected });
                this.pushMessage({
                    type: "conversation",
                    destination: this.selected,
                    transcript: this.getTranscript(this.selected),
                    entries: this.getEntries(this.selected),
                });
                break;
            }

            case "select": {
                this.selected = action.destination;
                if (this.selected.kind === "room") {
                    const room = this.state.daemon.rooms.find((r) => r.name === this.selected.id);
                    if (room) {
                        room.unread = 0;
                    }
                } else if (this.selected.kind === "dm") {
                    const profile = this.state.daemon.profiles.find((p) => p.name === this.selected.id);
                    if (profile) {
                        profile.unread = 0;
                    }
                } else if (this.selected.kind === "pings") {
                    this.state.daemon.humanEvents = 0;
                }

                this.pushMessage({ type: "state", state: this.state });
                this.pushMessage({ type: "selection", destination: this.selected });
                this.pushMessage({
                    type: "conversation",
                    destination: this.selected,
                    transcript: this.getTranscript(this.selected),
                    entries: this.getEntries(this.selected),
                });
                break;
            }

            case "post": {
                const key = `${action.source}:${action.target}`;
                const entry: Entry = {
                    id: `msg-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
                    ts: Date.now(),
                    from: "human",
                    text: action.text,
                    ...(action.source === "room" ? { room: action.target } : {}),
                    ...(action.source === "dm" ? { to: action.target } : {}),
                };
                const list = this.entries.get(key) ?? [];
                list.push(entry);
                this.entries.set(key, list);

                if (action.source === "room") {
                    const room = this.state.daemon.rooms.find((r) => r.name === action.target);
                    if (room) {
                        room.count++;
                        room.lastTs = entry.ts;
                    }
                }

                for (const p of action.ping) {
                    const prof = this.state.daemon.profiles.find((pr) => pr.name.toLowerCase() === p.toLowerCase());
                    if (prof && (this.selected.kind !== "dm" || this.selected.id !== prof.name)) {
                        prof.unread++;
                    }
                }

                this.pushMessage({ type: "result", action: "post", ok: true, error: "" });
                this.pushMessage({ type: "state", state: this.state });
                this.pushMessage({
                    type: "conversation",
                    destination: this.selected,
                    transcript: null,
                    entries: this.getEntries(this.selected),
                });
                break;
            }

            case "createRoom": {
                const exists = this.state.daemon.rooms.some((r) => r.name === action.name);
                if (exists) {
                    this.pushMessage({ type: "result", action: "createRoom", ok: false, error: "Room already exists" });
                } else {
                    const newRoom: Room = {
                        name: action.name,
                        count: 0,
                        unread: 0,
                        lastTs: Date.now(),
                        membership: { owner: "human", admins: [], involved: null },
                    };
                    this.state.daemon.rooms.push(newRoom);
                    this.entries.set(`room:${action.name}`, []);
                    this.pushMessage({ type: "result", action: "createRoom", ok: true, error: "" });
                    this.pushMessage({ type: "state", state: this.state });
                }
                break;
            }

            case "deleteRoom": {
                this.state.daemon.rooms = this.state.daemon.rooms.filter((r) => r.name !== action.name);
                this.entries.delete(`room:${action.name}`);
                this.pushMessage({ type: "state", state: this.state });
                if (this.selected.kind === "room" && this.selected.id === action.name) {
                    const fallback = this.state.daemon.rooms[0]?.name ?? "general";
                    this.selected = { kind: "room", id: fallback };
                    this.pushMessage({ type: "selection", destination: this.selected });
                    this.pushMessage({
                        type: "conversation",
                        destination: this.selected,
                        transcript: null,
                        entries: this.getEntries(this.selected),
                    });
                }
                this.pushMessage({ type: "result", action: "deleteRoom", ok: true, error: "" });
                break;
            }

            case "membership": {
                const room = this.state.daemon.rooms.find((r) => r.name === action.name);
                if (room) {
                    room.membership.involved = action.involved;
                }
                this.pushMessage({ type: "result", action: "membership", ok: true, error: "" });
                this.pushMessage({ type: "state", state: this.state });
                break;
            }

            case "roomAdmin": {
                const room = this.state.daemon.rooms.find((r) => r.name === action.name);
                if (room) {
                    if (action.remove) {
                        room.membership.admins = room.membership.admins.filter((a) => a !== action.profile);
                    } else if (!room.membership.admins.includes(action.profile)) {
                        room.membership.admins.push(action.profile);
                    }
                }
                this.pushMessage({ type: "result", action: "roomAdmin", ok: true, error: "" });
                this.pushMessage({ type: "state", state: this.state });
                break;
            }

            case "resume": {
                const tr = this.transcripts.get(`session:${action.session}`) ?? {
                    session: this.state.daemon.sessions.find((s) => s.id === action.session) ?? null,
                    execution: null,
                    messages: [],
                };
                tr.messages.push({
                    role: "user",
                    content: action.prompt,
                    timestamp: Date.now(),
                });
                this.transcripts.set(`session:${action.session}`, tr);
                this.pushMessage({ type: "result", action: "resume", ok: true, error: "" });
                this.pushMessage({
                    type: "conversation",
                    destination: this.selected,
                    transcript: tr,
                    entries: [],
                });
                break;
            }

            case "start": {
                const newId = `session-${Date.now()}`;
                const newSession: Session = {
                    id: newId,
                    title: action.prompt.slice(0, 32),
                    model: action.model || "swe-2-medium",
                    mode: action.mode || "auto",
                    directory: this.state.workspace,
                    status: "online",
                    executionId: null,
                    lastActivityAt: Math.floor(Date.now() / 1000),
                    createdAt: Date.now(),
                    profile: action.profile || null,
                };
                this.state.daemon.sessions.push(newSession);
                if (action.profile) {
                    const prof = this.state.daemon.profiles.find((p) => p.name === action.profile);
                    if (prof) {
                        prof.session = newSession;
                    } else {
                        this.state.daemon.profiles.push({
                            name: action.profile,
                            session: newSession,
                            managed: true,
                            events: 0,
                            schedules: 0,
                            unread: 0,
                        });
                    }
                }
                this.transcripts.set(`session:${newId}`, {
                    session: newSession,
                    execution: null,
                    messages: [{ role: "user", content: action.prompt, timestamp: Date.now() }],
                });
                this.pushMessage({ type: "result", action: "start", ok: true, error: "" });
                this.pushMessage({ type: "state", state: this.state });
                break;
            }

            case "stop":
            case "removeSession": {
                if (action.type === "removeSession") {
                    this.state.daemon.sessions = this.state.daemon.sessions.filter((s) => s.id !== action.id);
                    for (const p of this.state.daemon.profiles) {
                        if (p.session?.id === action.id) {
                            p.session = null;
                        }
                    }
                }
                this.pushMessage({ type: "result", action: action.type, ok: true, error: "" });
                this.pushMessage({ type: "state", state: this.state });
                break;
            }

            case "permission": {
                this.state.daemon.permissions = this.state.daemon.permissions.filter((p) => p.id !== action.id);
                this.pushMessage({ type: "result", action: "permission", ok: true, error: "" });
                this.pushMessage({ type: "state", state: this.state });
                break;
            }

            case "loadSchedules": {
                const list = this.schedules.get(action.profile) ?? [];
                this.pushMessage({ type: "schedules", profile: action.profile, schedules: list });
                break;
            }

            case "schedule": {
                const list = this.schedules.get(action.profile) ?? [];
                const schedType = String(action.schedule["type"] ?? "ping") as "clock" | "room" | "dm" | "ping";
                const sched: Schedule = {
                    id: `sched-${Date.now()}`,
                    type: schedType,
                    room: typeof action.schedule["room"] === "string" ? action.schedule["room"] : null,
                    from: typeof action.schedule["from"] === "string" ? action.schedule["from"] : null,
                    every: typeof action.schedule["every"] === "number" ? action.schedule["every"] : null,
                    at: typeof action.schedule["at"] === "string" ? action.schedule["at"] : null,
                    next: 0,
                };
                list.push(sched);
                this.schedules.set(action.profile, list);
                this.pushMessage({ type: "result", action: "schedule", ok: true, error: "" });
                this.pushMessage({ type: "schedules", profile: action.profile, schedules: list });
                break;
            }

            case "cancelSchedule": {
                let list = this.schedules.get(action.profile) ?? [];
                list = list.filter((s) => s.id !== action.id);
                this.schedules.set(action.profile, list);
                this.pushMessage({ type: "result", action: "cancelSchedule", ok: true, error: "" });
                this.pushMessage({ type: "schedules", profile: action.profile, schedules: list });
                break;
            }

            case "loadEvents": {
                const list = this.events.get(action.profile) ?? [];
                this.pushMessage({ type: "events", profile: action.profile, events: list });
                break;
            }

            case "saveSettings":
            case "savePolicy":
            case "saveDaemon": {
                this.pushMessage({ type: "result", action: action.type, ok: true, error: "" });
                break;
            }

            case "newSession": {
                this.pushMessage({ type: "newSession" });
                break;
            }
        }
    }
}

export const test = base.extend<{ harness: TestHarness }>({
    harness: async ({}, use) => {
        const harness = new TestHarness();
        await harness.start();
        await use(harness);
        await harness.stop();
    },
});

export { expect };
