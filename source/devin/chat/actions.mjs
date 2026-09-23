// The human's seat on the bus, as plain functions — what used to live inside
// the HTTP server, lifted out so the Devin Desktop extension can own the bus
// directly: the same JSONL files, the same agent-coord-mcp store module, the
// same shapes, no server in the middle and no second implementation.
//
// Every function takes a context object — { store, coordDir, project,
// teamRoom, human } — where `store` is the package's store module, imported by
// the caller (the extension host resolves it from the clone).

import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import path from "node:path";

export function watchedFiles({ store, coordDir, teamRoom, human })
{
    const files = new Set([store.roomFile(store.DEFAULT_ROOM), store.roomFile(teamRoom), store.inboxFile(human)]);
    const dir = path.join(coordDir, "rooms");
    if (existsSync(dir))
        for (const name of readdirSync(dir))
            if (name.endsWith(".jsonl"))
                files.add(path.join(dir, name));
    return [...files];
}

export function decorate(entry, file, { store, coordDir })
{
    const isDm = path.dirname(file) === path.join(coordDir, "inbox");
    return {
        ...entry,
        stream: isDm ? "dm" : "room",
        room: isDm ? undefined : entry.room ?? store.normalizeRoom(path.basename(file, ".jsonl")),
    };
}

export async function registerHuman({ store, project, teamRoom, human })
{
    await store.updateJson(store.AGENTS_FILE, {}, (registry) =>
    {
        const previous = registry[human] ?? {};
        registry[human] = {
            agentId: human,
            project,
            role: "user",
            registeredAt: previous.registeredAt ?? Date.now(),
            lastHeartbeat: Date.now(),
            proseOnly: {
                since: previous.proseOnly?.since ?? Date.now(),
                reason: "The user; speaks in prose through the team room",
            },
        };
        return registry;
    });
    // Default channels so the room list is not a single line. Topics are hints,
    // not rules; anything project-specific gets created by the people who need it.
    const defaultRooms = [
        { name: "general", topic: "the room — talk, decisions, anything the whole team sees" },
        { name: "market", topic: "job market reads — supply finds, gate verdicts, comp data, anything search-shaped" },
        { name: "leisure", topic: "unstructured exploration — side interests, paper reads, anything not-work that feeds the work" },
        { name: "news", topic: "industry news worth the team knowing — model releases, agent-infra moves, hiring climate" },
        { name: "brags", topic: "wins, catches, and clean sends — the ledger of the stuff that went right" },
    ];
    for (const room of [teamRoom, ...defaultRooms.map((room) => room.name)])
    {
        await store.ensureRoom(room, human);
        await store.addMember(room, human);
    }
    for (const room of defaultRooms)
        await store.setRoomMeta(room.name, { topic: room.topic }, human);
    const inbox = store.inboxFile(human);
    if (!existsSync(inbox))
    {
        mkdirSync(path.dirname(inbox), { recursive: true });
        writeFileSync(inbox, "", "utf8");
    }
}

export async function touchHeartbeat({ store, human })
{
    await store.updateJson(store.AGENTS_FILE, {}, (registry) =>
    {
        if (registry[human])
            registry[human].lastHeartbeat = Date.now();
        return registry;
    });
}

export async function say(ctx, room, text, kind, inReplyTo)
{
    const { store, human } = ctx;
    const name = store.normalizeRoom(room);
    await store.ensureRoom(name, human);
    await store.addMember(name, human);
    const entry = {
        id: randomUUID(),
        ts: Date.now(),
        from: human,
        room: name,
        text,
        ...(kind && kind !== "chatter" ? { kind } : {}),
        ...(inReplyTo ? { inReplyTo } : {}),
    };
    await store.appendJsonl(store.roomFile(name), entry);
    const pinged = await fanoutMentions(ctx, name, text);
    return { entry, pinged };
}

export async function dm(ctx, to, text, inReplyTo, from = ctx.human)
{
    const { store, human } = ctx;
    const entry = { id: randomUUID(), ts: Date.now(), from, to, text, ...(inReplyTo ? { inReplyTo } : {}) };
    await store.appendJsonl(store.inboxFile(to), entry);
    // Mirror into the sender's own inbox: the DM view reads only the human's
    // inbox, so without this a sent DM would never render in the sender's view.
    // Agent-authored DMs skip the mirror — their coord server tracks the send
    // itself, and the human's inbox is not a copy of every agent's.
    if (from === human)
        await store.appendJsonl(store.inboxFile(human), entry);
    return entry;
}

// An @-mention in a room message also lands in the mentioned agent's inbox:
// a room line only surfaces on an agent's next poll, an inbox DM is the
// interrupt. @everyone (or @all) pings every registered agent, and #room pings
// every member of that room.
export async function fanoutMentions(ctx, room, text, from = ctx.human)
{
    const { store, human } = ctx;
    let registry = {};
    try
    {
        registry = JSON.parse(readFileSync(store.AGENTS_FILE, "utf8").trim() || "{}");
    }
    catch
    {
        return [];
    }
    const agents = Object.keys(registry).filter((id) => id !== human);
    const mentioned = new Set();
    if (/@(everyone|all)\b/i.test(text))
        for (const id of agents)
            mentioned.add(id);
    for (const match of text.matchAll(/@([A-Za-z0-9_-]+)/g))
        if (agents.includes(match[1]))
            mentioned.add(match[1]);
    const rooms = await store.getRooms().catch(() => ({}));
    for (const match of text.matchAll(/#([A-Za-z0-9_-]+)/g))
        for (const member of rooms[match[1]]?.members ?? [])
            if (member !== human && registry[member])
                mentioned.add(member);
    mentioned.delete(from);
    const preview = text.length > 300 ? `${text.slice(0, 300)}…` : text;
    for (const id of mentioned)
    {
        try
        {
            await dm(ctx, id, `[PING] ${from} in #${room}: ${preview}`, undefined, from);
        }
        catch (err)
        {
            console.error(`ping fanout to ${id} failed: ${err?.message ?? err}`);
            mentioned.delete(id);
        }
    }
    return [...mentioned];
}

export async function roomList({ store })
{
    const registry = await store.getRooms();
    const ret = [];
    for (const [name, meta] of Object.entries(registry))
    {
        const entries = await store.readJsonl(store.roomFile(name));
        ret.push({
            name,
            topic: meta.topic ?? "",
            motd: meta.motd ?? "",
            members: meta.members ?? [],
            count: entries.length,
            lastTs: entries.length ? entries[entries.length - 1].ts : null,
        });
    }
    return ret.sort((a, b) => (b.lastTs ?? 0) - (a.lastTs ?? 0));
}

export async function history({ store, human }, limit)
{
    const rooms = await roomList({ store });
    const all = [];
    for (const room of rooms)
        for (const entry of await store.readJsonl(store.roomFile(room.name)))
            all.push({ ...entry, stream: "room", room: entry.room ?? room.name });
    for (const entry of await store.readJsonl(store.inboxFile(human)))
        all.push({ ...entry, stream: "dm" });
    all.sort((a, b) => a.ts - b.ts);
    return all.slice(-limit);
}

// Presence is derived, not requested: an agent is as old as the newest bus line
// it authored (kept current by the pump's activity map) or the mtime of its read
// cursor, which the coord server touches on every wait/read call.
export function registryView({ store, coordDir, activity })
{
    let raw = {};
    try
    {
        raw = JSON.parse(readFileSync(store.AGENTS_FILE, "utf8").trim() || "{}");
    }
    catch
    {
        // A registry mid-rewrite is not a reason to fail the whole view over.
    }
    const cursorsDir = path.join(coordDir, "cursors");
    const now = Date.now();
    return Object.values(raw)
        .map((agent) =>
        {
            let cursorTs = 0;
            try
            {
                cursorTs = statSync(path.join(cursorsDir, `${agent.agentId}.json`)).mtimeMs;
            }
            catch { }
            const lastActive = Math.max(activity.get(agent.agentId) ?? 0, cursorTs);
            return {
                id: agent.agentId,
                role: agent.role ?? "",
                project: agent.project ?? "",
                lastActive,
                online: now - lastActive < 30 * 60_000,
            };
        })
        .sort((a, b) => a.id.localeCompare(b.id));
}
