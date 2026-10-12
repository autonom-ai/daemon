export type SessionStatus = "offline" | "starting" | "online" | "loaded" | "stopping" | "failed";
export type PermissionMode = "auto" | "accept-edits" | "smart" | "bypass";
export type Destination = { kind: "session" | "run" | "room" | "dm" | "pings"; id: string };

export type Session = {
    id: string;
    title: string;
    model: string;
    mode: string;
    directory: string;
    status: SessionStatus;
    executionId: string | null;
    lastActivityAt: number;
    createdAt: number;
    profile?: string | null;
};

export type Profile = {
    name: string;
    session: Session | null;
    managed: boolean;
    events: number;
    schedules: number;
    unread: number;
};

export type Execution = {
    id: string;
    kind: string;
    status: string;
    sessionId: string | null;
    workspace: string;
    model: string;
    profile: string;
    mode: string;
    createdAt: string;
    finishedAt: string | null;
    error: string | null;
};

export type Room = {
    name: string;
    count: number;
    unread: number;
    lastTs: number | null;
    membership: { owner: string; admins: string[]; involved: string[] | null };
};

export type Entry = {
    id: string;
    ts: number;
    from: string;
    text: string;
    to?: string;
    room?: string;
};

export type PendingPermission = {
    id: string;
    session: string;
    tool: string;
    input: Record<string, unknown>;
    createdAt: number;
};

export type DaemonState = {
    profiles: Profile[];
    sessions: Session[];
    runs: Execution[];
    rooms: Room[];
    permissions: PendingPermission[];
    humanEvents: number;
};

export type Model = { id: string; label: string; family: string; cost: string };
export type ConversationMessage = Record<string, unknown>;
export type Transcript = {
    session: Session | null;
    execution: Execution | null;
    messages: ConversationMessage[];
};

export type Schedule = {
    id: string;
    type: "clock" | "room" | "dm" | "ping";
    room: string | null;
    from: string | null;
    every: number | null;
    at: string | null;
    next: number;
};

export type Event = { id: string; type: string; text: string; from: string | null; room: string | null; ts: number };

export type Settings = {
    rootDirectory: string;
    configFile: string;
    port: number;
    defaultModel: string;
    permissionMode: PermissionMode;
    pollIntervalMs: number;
    notifyPings: boolean;
};

export type ConfigurationState = {
    workspace: string;
    installed: boolean;
    policy: string;
    policyVersion: string;
    daemon: Record<string, unknown>;
    routerConfigured: boolean;
};

export type ViewState = {
    connected: boolean;
    error: string;
    workspace: string;
    workspaceName: string;
    settings: Settings;
    configuration: ConfigurationState | null;
    daemon: DaemonState;
    models: Model[];
};

export type HostAction =
    | { type: "ready" | "refresh" | "open" | "settings" | "newSession" | "setup" | "editPolicy" | "editConfig" | "configureKey" }
    | { type: "select"; destination: Destination }
    | { type: "start"; prompt: string; profile: string; model: string; mode: PermissionMode }
    | { type: "resume"; session: string; prompt: string; model: string; mode: PermissionMode }
    | { type: "stop" | "removeSession"; id: string; run: boolean }
    | { type: "post"; source: "room" | "dm"; target: string; text: string; ping: string[] }
    | { type: "createRoom" | "deleteRoom"; name: string }
    | { type: "membership"; name: string; involved: string[] | null }
    | { type: "roomAdmin"; name: string; profile: string; remove: boolean }
    | { type: "permission"; id: string; decision: "approve" | "block" }
    | { type: "loadSchedules" | "loadEvents"; profile: string }
    | { type: "schedule"; profile: string; schedule: Record<string, unknown> }
    | { type: "cancelSchedule"; profile: string; id: string }
    | { type: "saveSettings"; settings: Settings }
    | { type: "savePolicy"; text: string; version: string }
    | { type: "saveDaemon"; values: Record<string, unknown> }
    | { type: "openLink"; href: string };

export type HostMessage =
    | { type: "state"; state: ViewState }
    | { type: "selection"; destination: Destination }
    | { type: "conversation"; destination: Destination; transcript: Transcript | null; entries: Entry[] }
    | { type: "schedules"; profile: string; schedules: Schedule[] }
    | { type: "events"; profile: string; events: Event[] }
    | { type: "newSession" }
    | { type: "result"; action: string; ok: boolean; error: string };

export function record(value: unknown): Record<string, unknown> | undefined
{
    return typeof value === "object" && value !== null && !Array.isArray(value)
        ? value as Record<string, unknown> : undefined;
}

export function text(value: unknown, fallback = ""): string
{
    return typeof value === "string" ? value : fallback;
}

export function destination(value: unknown): Destination | undefined
{
    const item = record(value);
    if (item === undefined || typeof item.id !== "string" || item.id.length > 128
        || !["session", "run", "room", "dm", "pings"].includes(text(item.kind)))
        return undefined;
    return { kind: item.kind as Destination["kind"], id: item.id };
}

export function emptyDaemon(): DaemonState
{
    return { profiles: [], sessions: [], runs: [], rooms: [], permissions: [], humanEvents: 0 };
}

export function modelCatalog(value: unknown): Model[]
{
    const catalog = record(value);
    if (!Array.isArray(catalog?.families))
        return [];
    const ret: Model[] = [];
    for (const item of catalog.families)
    {
        const family = record(item);
        if (!Array.isArray(family?.variants))
            continue;
        for (const item of family.variants)
        {
            const variant = record(item);
            if (!text(variant?.model_uid))
                continue;
            ret.push({
                id: text(variant?.model_uid),
                label: text(variant?.label, text(variant?.model_uid)),
                family: text(family.family_label),
                cost: text(variant?.cost_summary, text(variant?.cost_tier)),
            });
        }
    }
    return ret;
}
