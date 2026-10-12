import { DaemonClient } from "./client";
import { configurationState } from "./config";
import { destination, emptyDaemon, modelCatalog, record, text } from "../protocol";
import type {
    DaemonState,
    Destination,
    Entry,
    Execution,
    HostMessage,
    Settings,
    Transcript,
    ViewState,
} from "../protocol";

import { basename } from "node:path";

export type HostServices = {
    workspace: () => string;
    trusted: () => boolean;
    send: (message: HostMessage) => void;
    confirm: (message: string, detail: string) => Promise<boolean>;
    localAction: (type: string, message: Record<string, unknown>) => Promise<void>;
};

export class Controller
{
    readonly client: DaemonClient;
    private services: HostServices;
    private selection: Destination | undefined;
    private refreshing: Promise<void> | undefined;
    private configurationLoaded = false;
    private modelsLoaded = false;
    state: ViewState;

    constructor(settings: Settings, services: HostServices)
    {
        this.services = services;
        this.client = new DaemonClient(settings);
        this.state = {
            connected: false,
            error: "",
            workspace: services.workspace(),
            workspaceName: basename(services.workspace()),
            settings,
            configuration: null,
            daemon: emptyDaemon(),
            models: [],
        };
    }

    configure(settings: Settings): void
    {
        this.state.settings = settings;
        this.client.configure(settings);
        this.configurationLoaded = false;
        this.modelsLoaded = false;
    }

    invalidateConfiguration(): void
    {
        this.configurationLoaded = false;
    }

    refresh(): Promise<void>
    {
        if (this.refreshing !== undefined)
            return this.refreshing;
        const ret = this.load().finally(() => { this.refreshing = undefined; });
        this.refreshing = ret;
        return ret;
    }

    async handle(value: unknown): Promise<void>
    {
        const message = record(value);
        const action = text(message?.type);
        if (message === undefined || !action)
            return;
        if (Buffer.byteLength(JSON.stringify(message), "utf8") > 131072)
        {
            this.result(action, false, "Action exceeds the input size limit.");
            return;
        }
        try
        {
            if (action === "ready" || action === "refresh")
            {
                this.configurationLoaded = false;
                await this.refresh();
                return;
            }
            if (action === "select")
            {
                const selected = destination(message.destination);
                if (selected === undefined)
                    throw new Error("Invalid conversation selection.");
                this.selection = selected;
                await this.loadConversation(selected);
                return;
            }
            if (["open", "settings", "newSession", "setup", "editPolicy", "editConfig", "saveSettings", "savePolicy",
                "saveDaemon", "configureKey", "openLink"].includes(action))
            {
                await this.services.localAction(action, message);
                this.configurationLoaded = false;
                this.result(action, true);
                await this.refresh();
                return;
            }
            this.requireTrusted();
            await this.execute(action, message);
            this.result(action, true);
            await this.refresh();
        }
        catch (error)
        {
            this.result(action, false, error instanceof Error ? error.message : "Autonom action failed.");
        }
    }

    async select(destination: Destination): Promise<void>
    {
        this.selection = destination;
        this.services.send({ type: "selection", destination });
        await this.loadConversation(destination);
    }

    private async load(): Promise<void>
    {
        this.state.workspace = this.services.workspace();
        this.state.workspaceName = basename(this.state.workspace);
        try
        {
            this.requireTrusted();
            await this.client.connect();
            this.state.daemon = await this.client.request<DaemonState>(
                "/api/client/state?directory=" + encodeURIComponent(this.state.workspace));
            if (!this.configurationLoaded)
            {
                this.state.configuration = await configurationState(this.state.workspace, this.client.configurationPath);
                this.configurationLoaded = true;
            }
            this.state.connected = true;
            this.state.error = "";
        }
        catch (error)
        {
            this.state.connected = false;
            this.state.error = error instanceof Error ? error.message : "Autonom connection failed.";
        }
        this.services.send({ type: "state", state: this.state });
        if (!this.state.connected)
            return;
        if (!this.modelsLoaded)
        {
            this.modelsLoaded = true;
            void this.client.request<unknown>("/api/client/models").then((catalog) =>
            {
                this.state.models = modelCatalog(catalog);
                this.services.send({ type: "state", state: this.state });
            }).catch(() => { this.modelsLoaded = false; });
        }
        const selected = this.selection;
        if (selected === undefined)
            return;
        if (selected.kind === "run")
        {
            const run = this.state.daemon.runs.find((run) => run.id === selected.id);
            if (run?.sessionId)
            {
                this.selection = { kind: "session", id: run.sessionId };
                this.services.send({ type: "selection", destination: this.selection });
            }
        }
        await this.loadConversation(this.selection ?? selected);
    }

    private async loadConversation(selected: Destination): Promise<void>
    {
        if (!this.state.connected)
            return;
        if (selected.kind === "session" || selected.kind === "run")
        {
            const transcript = await this.client.request<Transcript>("/api/client/transcript/" + name(selected.id));
            this.services.send({ type: "conversation", destination: selected, transcript, entries: [] });
        }
        else
        {
            const entries = await this.client.request<Entry[]>("/api/client/messages?source=" + selected.kind
                + "&target=" + name(selected.id));
            this.services.send({ type: "conversation", destination: selected, entries, transcript: null });
        }
    }

    private async execute(action: string, message: Record<string, unknown>): Promise<void>
    {
        const client = this.client;
        switch (action)
        {
            case "start":
            {
                if (!this.state.configuration?.installed)
                    throw new Error("Set up the workspace from the Control Center before starting a session.");
                const prompt = required(message, "prompt", 48000);
                const profile = text(message.profile).trim();
                if (profile && !/^[a-z0-9][a-z0-9_-]{0,63}$/i.test(profile))
                    throw new Error("Profile names use letters, numbers, hyphens, and underscores.");
                const execution = await client.request<Execution>("/api/sessions", "POST", {
                    prompt,
                    profile,
                    directory: this.state.workspace,
                    model: required(message, "model", 128),
                    mode: mode(message.mode),
                    trusted: true,
                });
                await this.select({ kind: "run", id: execution.id });
                break;
            }
            case "resume":
            {
                const session = this.state.daemon.sessions.find((session) => session.id === message.session);
                if (session === undefined)
                    throw new Error("Only managed sessions in this workspace can be resumed.");
                await client.request("/api/sessions/" + name(session.id) + "/resume", "POST", {
                    prompt: required(message, "prompt", 48000),
                    directory: this.state.workspace,
                    model: text(message.model, session.model),
                    mode: mode(message.mode),
                });
                break;
            }
            case "stop":
                await client.request((message.run ? "/api/executions/" : "/api/sessions/")
                    + name(required(message, "id", 128)) + "/stop", "POST", {});
                break;
            case "removeSession":
                if (await this.services.confirm("Delete this session?", "This removes its saved conversation permanently."))
                    await client.request("/api/sessions/" + name(required(message, "id", 128)), "DELETE");
                break;
            case "post":
            {
                const target = name(required(message, "target", 64));
                const ping = stringList(message.ping);
                const body = { text: required(message, "text", 4000), ping };
                if (message.source === "room")
                    await client.request("/api/rooms/" + target + "/messages", "POST", body);
                else if (message.source === "dm")
                    await client.request("/api/messages", "POST", { ...body, to: required(message, "target", 64) });
                else
                    throw new Error("Unknown message destination.");
                break;
            }
            case "createRoom":
                await client.request("/api/rooms", "POST", { name: required(message, "name", 64) });
                await this.select({ kind: "room", id: text(message.name).replace(/^#/, "").toLowerCase() });
                break;
            case "deleteRoom":
                if (await this.services.confirm("Delete this room?", "Its message history will be permanently removed."))
                {
                    await client.request("/api/rooms/" + name(required(message, "name", 64)), "DELETE");
                    this.selection = undefined;
                }
                break;
            case "membership":
                await client.request("/api/rooms/" + name(required(message, "name", 64)) + "/membership", "POST", {
                    involved: message.involved === null ? null : stringList(message.involved),
                });
                break;
            case "roomAdmin":
            {
                const path = "/api/rooms/" + name(required(message, "name", 64)) + "/admins";
                const profile = required(message, "profile", 64);
                if (message.remove)
                    await client.request(path + "?profile=" + name(profile), "DELETE");
                else
                    await client.request(path, "POST", { profile });
                break;
            }
            case "permission":
                if (message.decision !== "approve" && message.decision !== "block")
                    throw new Error("Invalid permission decision.");
                await client.request("/api/permissions/" + name(required(message, "id", 128)), "POST", {
                    decision: message.decision,
                });
                break;
            case "loadSchedules":
                this.services.send({ type: "schedules", profile: text(message.profile), schedules:
                    await client.request("/api/schedules?profile=" + name(required(message, "profile", 64))) });
                break;
            case "loadEvents":
                this.services.send({ type: "events", profile: text(message.profile), events:
                    await client.request("/api/client/events?profile=" + name(required(message, "profile", 64))) });
                break;
            case "schedule":
                await client.request("/api/schedules?profile=" + name(required(message, "profile", 64)), "POST",
                    record(message.schedule) ?? {});
                await this.execute("loadSchedules", message);
                break;
            case "cancelSchedule":
                await client.request("/api/schedules/" + name(required(message, "id", 128))
                    + "?profile=" + name(required(message, "profile", 64)), "DELETE");
                await this.execute("loadSchedules", message);
                break;
            default:
                throw new Error("Unsupported Autonom action.");
        }
    }

    private requireTrusted(): void
    {
        if (!this.services.trusted())
            throw new Error("Trust this workspace before starting Autonom.");
        if (!this.services.workspace())
            throw new Error("Open a workspace folder to use Autonom.");
    }

    private result(action: string, ok: boolean, error = ""): void
    {
        this.services.send({ type: "result", action, ok, error });
    }
}

function required(message: Record<string, unknown>, field: string, limit: number): string
{
    const ret = text(message[field]);
    if (!ret.trim() || ret.length > limit || ret.includes("\0"))
        throw new Error(`Invalid ${field}.`);
    return ret;
}

function stringList(value: unknown): string[]
{
    if (!Array.isArray(value) || value.length > 100 || value.some((item) => typeof item !== "string" || item.length > 64))
        throw new Error("Expected a list of profile names.");
    return value as string[];
}

function name(value: string): string
{
    return encodeURIComponent(value);
}

function mode(value: unknown): string
{
    if (!["auto", "accept-edits", "smart", "bypass"].includes(text(value)))
        throw new Error("Unknown permission mode.");
    return text(value);
}
