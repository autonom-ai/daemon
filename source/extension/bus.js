// The extension host's view of one workspace's chat.
//
// Rooms are workspace-scoped — <project>/.devin/agent-coord/rooms/<room>.jsonl.
// DMs and pings are profile-scoped — <coordRoot>/agents/<name>/inbox.jsonl and
// pings.jsonl — so they follow a person across workspaces. The human is a
// profile like anyone else; the Ruby core reads and writes the same files.

const { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } = require("node:fs");
const { randomUUID } = require("node:crypto");
const path = require("node:path");

const NAME_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/;
const MENTION_PATTERN = /@([A-Za-z0-9_-]+)/g;
const EVERYONE_PATTERN = /@(everyone|all)\b/i;
const ONLINE_MS = 30 * 60_000;
const HISTORY_LIMIT = 400;

function readJson(file, fallback)
{
    try
    {
        const raw = readFileSync(file, "utf8");
        return raw.trim() ? JSON.parse(raw) : fallback;
    }
    catch
    {
        return fallback;
    }
}

function readJsonl(file)
{
    if (!existsSync(file))
        return [];
    const ret = [];
    for (const line of readFileSync(file, "utf8").split("\n"))
    {
        if (!line.trim())
            continue;
        try
        {
            ret.push(JSON.parse(line));
        }
        catch
        {
            // A malformed line is not a reason to lose the rest of the file.
        }
    }
    return ret;
}

function appendJsonl(file, entry)
{
    mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    appendFileSync(file, `${JSON.stringify(entry)}\n`, "utf8");
}

function chatEntry(from, text, extra)
{
    return { id: randomUUID(), ts: Date.now(), from, text, ...extra };
}

function normalizeRoom(name)
{
    return String(name ?? "").trim().replace(/^#+/, "").toLowerCase();
}

function chatDir(projectDir)
{
    return path.join(projectDir, ".devin", "agent-coord");
}

function roomFile(projectDir, room)
{
    return path.join(chatDir(projectDir), "rooms", `${normalizeRoom(room)}.jsonl`);
}

function roomNames(projectDir, teamRoom)
{
    const names = new Set([normalizeRoom(teamRoom)]);
    const dir = path.join(chatDir(projectDir), "rooms");
    if (existsSync(dir))
        for (const name of readdirSync(dir))
            if (name.endsWith(".jsonl"))
                names.add(name.slice(0, -".jsonl".length));
    return [...names].filter(Boolean);
}

function profileDir(coordRoot, name)
{
    return path.join(coordRoot, "agents", name);
}

function inboxFile(coordRoot, name)
{
    return path.join(profileDir(coordRoot, name), "inbox.jsonl");
}

function pingsFile(coordRoot, name)
{
    return path.join(profileDir(coordRoot, name), "pings.jsonl");
}

function pingsCursorFile(coordRoot, name)
{
    return path.join(profileDir(coordRoot, name), "pings.cursor");
}

// The same cursor the Ruby core keeps: pings up to this count have been
// delivered. The human's pings are delivered here (notification + badge);
// an agent's are delivered on its next tool call.
function pingCursor(coordRoot, name)
{
    try
    {
        return parseInt(readFileSync(pingsCursorFile(coordRoot, name), "utf8"), 10) || 0;
    }
    catch
    {
        return 0;
    }
}

function advancePingCursor(coordRoot, name, count)
{
    const file = pingsCursorFile(coordRoot, name);
    mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    writeFileSync(file, String(count), "utf8");
}

// displayName + color from agents/<id>/identity.md — the room renders people by
// who they are, not by directory name.
function identityMeta(coordRoot, id)
{
    let raw = "";
    try
    {
        raw = readFileSync(path.join(profileDir(coordRoot, id), "identity.md"), "utf8");
    }
    catch
    {
        return { display: id, color: null };
    }
    const front = /^---\n([\s\S]*?)\n---/.exec(raw);
    const meta = {};
    if (front)
        for (const line of front[1].split("\n"))
        {
            const match = /^(\w[\w-]*):\s*(.*)$/.exec(line.trim());
            if (match)
                meta[match[1]] = match[2];
        }
    const color = (meta.color ?? "").trim().replace(/^["']|["']$/g, "");
    return {
        display: meta.displayName?.trim() || id,
        color: color && color !== "null" ? color : null,
    };
}

function profiles(coordRoot)
{
    const dir = path.join(coordRoot, "agents");
    if (!existsSync(dir))
        return [];
    return readdirSync(dir, { withFileTypes: true })
        .filter((entry) => entry.isDirectory() && NAME_PATTERN.test(entry.name))
        .map((entry) => ({ id: entry.name, ...identityMeta(coordRoot, entry.name) }))
        .sort((a, b) => a.id.localeCompare(b.id));
}

function ensureProfile(coordRoot, name)
{
    if (NAME_PATTERN.test(name))
        mkdirSync(profileDir(coordRoot, name), { recursive: true, mode: 0o700 });
}

// @-mentions in the human's message become pings: DMs never ping on their own,
// and agents name their ping targets explicitly in the MCP call instead.
function mentionTargets(coordRoot, text, human)
{
    const known = profiles(coordRoot).map((profile) => profile.id);
    const targets = new Set();
    if (EVERYONE_PATTERN.test(text))
        for (const id of known)
            targets.add(id);
    for (const match of text.matchAll(MENTION_PATTERN))
    {
        const target = known.find((id) => id.toLowerCase() === match[1].toLowerCase());
        if (target)
            targets.add(target);
    }
    targets.delete(human);
    return [...targets];
}

function fanout(ctx, text, room)
{
    const targets = mentionTargets(ctx.coordRoot, text, ctx.human);
    for (const target of targets)
        appendJsonl(pingsFile(ctx.coordRoot, target), chatEntry(ctx.human, text, room ? { room } : undefined));
    return targets;
}

async function openBus({ projectDir, coordRoot })
{
    const config = readJson(path.join(projectDir, ".devin", "coord.json"), {});
    const ctx = {
        projectDir,
        coordRoot,
        project: config.project ?? path.basename(projectDir),
        teamRoom: config.teamRoom ?? "general",
        human: config.human ?? process.env.USER ?? "user",
    };
    ensureProfile(coordRoot, ctx.human);

    // One watched file per stream — every room and the human's inbox — each
    // carrying the kind it decorates entries with. The human's pings are read
    // whole, against their cursor, so a ping that lands while the extension is
    // closed is still delivered on the next open.
    function watched()
    {
        const files = new Map();
        for (const name of roomNames(projectDir, ctx.teamRoom))
            files.set(roomFile(projectDir, name), "room");
        files.set(inboxFile(coordRoot, ctx.human), "dm");
        return files;
    }

    const offsets = new Map();
    const pending = new Map();
    const activity = new Map();

    // One pass over the bus so a fresh extension does not blank every seat's
    // presence until their next message.
    function seedActivity()
    {
        for (const file of watched().keys())
            for (const entry of readJsonl(file))
                if (entry.from && entry.ts > (activity.get(entry.from) ?? 0))
                    activity.set(entry.from, entry.ts);
    }

    // Establish the pump's file offsets at open time, before anything can be
    // written: history comes from state(), and a message that lands while the
    // extension is still starting must not be swallowed as first-sight history.
    function seedOffsets()
    {
        for (const file of watched().keys())
        {
            let size = 0;
            try
            {
                size = statSync(file).size;
            }
            catch { }
            offsets.set(file, size);
        }
    }

    function decorate(kind, file, entry)
    {
        if (kind === "room")
            return { ...entry, stream: "room", room: path.basename(file, ".jsonl") };
        return { ...entry, stream: kind };
    }

    // Returns what was appended since the last call: entries for the room view,
    // and the human's unread pings for the badge and notifications.
    function pump()
    {
        const entries = [];
        for (const [file, kind] of watched())
        {
            let size = 0;
            try
            {
                size = statSync(file).size;
            }
            catch
            {
                continue;
            }
            if (!offsets.has(file))
                offsets.set(file, 0); // a room created by its first message is new content
            const start = offsets.get(file);
            if (size < start)
            {
                offsets.set(file, 0); // the file was truncated under us; re-read from the top
                pending.set(file, "");
                continue;
            }
            if (size === start)
                continue;
            let chunk;
            try
            {
                chunk = readFileSync(file).subarray(start).toString("utf8");
            }
            catch
            {
                continue;
            }
            offsets.set(file, size);
            const text = (pending.get(file) ?? "") + chunk;
            const lines = text.split("\n");
            pending.set(file, lines.pop() ?? "");
            for (const line of lines)
            {
                if (!line.trim())
                    continue;
                let entry;
                try
                {
                    entry = JSON.parse(line);
                }
                catch
                {
                    continue;
                }
                if (entry.from && entry.ts > (activity.get(entry.from) ?? 0))
                    activity.set(entry.from, entry.ts);
                entries.push(decorate(kind, file, entry));
            }
        }
        const pings = readJsonl(pingsFile(coordRoot, ctx.human));
        const unread = pings.slice(pingCursor(coordRoot, ctx.human));
        if (unread.length)
            advancePingCursor(coordRoot, ctx.human, pings.length);
        return { entries, pings: unread };
    }

    async function state()
    {
        const now = Date.now();
        const agents = profiles(coordRoot).map((profile) =>
        {
            const lastActive = activity.get(profile.id) ?? 0;
            return { ...profile, lastActive, online: now - lastActive < ONLINE_MS };
        });
        const rooms = roomNames(projectDir, ctx.teamRoom).map((name) =>
        {
            const roomEntries = readJsonl(roomFile(projectDir, name));
            return {
                name,
                count: roomEntries.length,
                lastTs: roomEntries.length ? roomEntries[roomEntries.length - 1].ts : null,
            };
        }).sort((a, b) => (b.lastTs ?? 0) - (a.lastTs ?? 0) || a.name.localeCompare(b.name));
        const messages = [];
        for (const room of rooms)
            for (const entry of readJsonl(roomFile(projectDir, room.name)))
                messages.push({ ...entry, stream: "room", room: room.name });
        for (const entry of readJsonl(inboxFile(coordRoot, ctx.human)))
            messages.push({ ...entry, stream: "dm" });
        messages.sort((a, b) => a.ts - b.ts);
        return {
            project: ctx.project,
            human: ctx.human,
            teamRoom: ctx.teamRoom,
            agents,
            rooms,
            messages: messages.slice(-HISTORY_LIMIT),
        };
    }

    async function say(room, text)
    {
        const name = normalizeRoom(room) || normalizeRoom(ctx.teamRoom);
        const entry = chatEntry(ctx.human, text);
        appendJsonl(roomFile(projectDir, name), entry);
        activity.set(ctx.human, entry.ts);
        return { entry: decorate("room", roomFile(projectDir, name), entry), pinged: fanout(ctx, text, name) };
    }

    // A DM lands in the recipient's inbox and mirrors into the human's own, so
    // the 1:1 view shows both directions. It pings nobody unless the text
    // names someone with @.
    async function dm(to, text)
    {
        const entry = chatEntry(ctx.human, text, { to });
        appendJsonl(inboxFile(coordRoot, to), entry);
        appendJsonl(inboxFile(coordRoot, ctx.human), entry);
        activity.set(ctx.human, entry.ts);
        return { entry: decorate("dm", inboxFile(coordRoot, ctx.human), entry), pinged: fanout(ctx, text, null) };
    }

    seedActivity();
    seedOffsets();
    return { ctx, projectDir, coordRoot, state, pump, say, dm };
}

module.exports = { openBus, readJson };
