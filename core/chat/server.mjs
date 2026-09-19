#!/usr/bin/env node
// Team chat — the human's seat on the same file-backed bus the seats use.
//
// The bus is JSONL on disk, so this is not a client of an API: it appends to the
// same files the coord servers read and tails the same files they write. It
// imports the coord package's own store module for that, so message shapes and
// file locks are the package's, not a second implementation of them.

import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { randomUUID, createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { endRecess, recessState, startRecess } from "./recess.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const coordRoot = path.resolve(here, "..", "..");
const projectDir = process.env.DEVIN_PROJECT_DIR ?? path.resolve(here, "..", "..");
const coordDir = process.env.AGENT_COORD_DIR ?? path.join(projectDir, ".devin", "agent-coord", "state");
// The pinned canonical install is preferred; a workspace-local install is the
// fallback for layouts that predate the canonical repo.
const storeCandidates = [
    process.env.AGENT_COORD_STORE,
    path.join(coordRoot, "node_modules", "agent-coord-mcp", "dist", "store.js"),
    path.join(projectDir, ".devin", "agent-coord", "node_modules", "agent-coord-mcp", "dist", "store.js"),
].filter(Boolean);
const storePath = storeCandidates.find((file) => existsSync(file));

if (!storePath)
{
    console.error(`team chat: agent-coord-mcp store.js not found in ${storeCandidates.join(" or ")}`);
    process.exit(1);
}

process.env.AGENT_COORD_DIR = coordDir;
const store = await import(pathToFileURL(storePath).href);

const args = parseArgs(process.argv.slice(2));
const host = args.host ?? "127.0.0.1";
const port = Number(args.port ?? process.env.COORD_CHAT_PORT ?? 7778);
const human = args.id ?? process.env.COORD_CHAT_ID ?? process.env.USER ?? "user";
const project = args.project ?? process.env.COORD_PROJECT ?? path.basename(projectDir);
const teamRoom = args.room ?? "general";
const standDownFile = path.join(projectDir, ".devin", "collaboration", "stand-down");
const publicDir = path.join(here, "public");

// Content stamp of the code being served, computed per request — public/ is
// re-read from disk on every GET, so a stamp frozen at startup would lie after
// the first front-end edit. Which build is live should be a fact the UI can
// show, not something you infer from a PID.
function buildStamp()
{
    const hash = createHash("sha1");
    const files = [path.join(here, "server.mjs"), ...readdirSync(publicDir).sort().map((name) => path.join(publicDir, name))];
    for (const file of files)
        try
        {
            hash.update(readFileSync(file));
        }
        catch { }
    return hash.digest("hex").slice(0, 10);
}
const startedAt = Date.now();

const offsets = new Map();
const pending = new Map();
const clients = new Set();

// ---------- bus ----------

function watchedFiles()
{
    const files = new Set([store.roomFile(store.DEFAULT_ROOM), store.roomFile(teamRoom), store.inboxFile(human)]);
    const dir = path.join(coordDir, "rooms");
    if (existsSync(dir))
        for (const name of readdirSync(dir))
            if (name.endsWith(".jsonl"))
                files.add(path.join(dir, name));
    return [...files];
}

function broadcast(payload)
{
    const frame = `data: ${JSON.stringify(payload)}\n\n`;
    for (const res of clients)
    {
        try
        {
            res.write(frame);
        }
        catch
        {
            clients.delete(res);
        }
    }
}

function pump()
{
    for (const file of watchedFiles())
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
        {
            offsets.set(file, size); // first sight: history comes from /api/state, not the stream
            continue;
        }
        const start = offsets.get(file);
        if (size < start)
        {
            offsets.set(file, 0); // the room compacted under us; re-read from the top
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
            broadcast({ type: "message", entry: decorate(entry, file) });
            // A RECESS / RECESS CLOSED decision may arrive from the CLI
            // (tools/coord-recess), which changes the marker file without
            // going through /api/recess. Re-broadcast the recess state so
            // every web client refreshes its banner.
            if (entry.kind === "decision" && typeof entry.text === "string" && entry.text.startsWith("RECESS"))
                broadcast({ type: "recess", state: recessState(projectDir) });
        }
    }
}

function decorate(entry, file)
{
    const isDm = path.dirname(file) === path.join(coordDir, "inbox");
    return {
        ...entry,
        stream: isDm ? "dm" : "room",
        room: isDm ? undefined : entry.room ?? store.normalizeRoom(path.basename(file, ".jsonl")),
    };
}

async function registerHuman()
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
                reason: "The user; speaks in prose through the team chat UI",
            },
        };
        return registry;
    });
    await store.ensureRoom(teamRoom, human);
    await store.addMember(teamRoom, human);
    // Default channels so the room list is not a single line. Topics are
    // hints, not rules — the team can redirect a conversation by moving rooms.
    // Anything project-specific gets created by the people who need it, not
    // seeded here.
    const defaultRooms = [
        { name: "general", topic: "the room — talk, decisions, anything the whole team sees" },
        { name: "ui", topic: "the team chat UI and anything front-of-house" },
    ];
    for (const room of defaultRooms)
    {
        await store.ensureRoom(room.name, human);
        await store.addMember(room.name, human);
        await store.setRoomMeta(room.name, { topic: room.topic }, human);
    }
    const inbox = store.inboxFile(human);
    if (!existsSync(inbox))
    {
        mkdirSync(path.dirname(inbox), { recursive: true });
        writeFileSync(inbox, "", "utf8");
    }
}

async function heartbeat()
{
    await store.updateJson(store.AGENTS_FILE, {}, (registry) =>
    {
        if (registry[human])
            registry[human].lastHeartbeat = Date.now();
        return registry;
    });
}

async function say(room, text, kind, inReplyTo)
{
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
    const pinged = await fanoutMentions(name, text);
    return { entry, pinged };
}

async function dm(to, text, inReplyTo)
{
    const entry = { id: randomUUID(), ts: Date.now(), from: human, to, text, ...(inReplyTo ? { inReplyTo } : {}) };
    await store.appendJsonl(store.inboxFile(to), entry);
    // Mirror into the sender's own inbox: the DM view (history + SSE pump)
    // reads only the human's inbox, so without this a sent DM would never
    // render in the sender's view — it existed only in the recipient's file.
    await store.appendJsonl(store.inboxFile(human), entry);
    return entry;
}

// An @-mention in a room message also lands in the mentioned seat's inbox:
// a room line only surfaces on a seat's next poll, an inbox DM is the
// interrupt. @everyone (or @all) pings every registered seat.
async function fanoutMentions(room, text)
{
    let registry = {};
    try
    {
        registry = JSON.parse(readFileSync(store.AGENTS_FILE, "utf8").trim() || "{}");
    }
    catch
    {
        return [];
    }
    const seats = Object.keys(registry).filter((id) => id !== human);
    // @ works on the seat id and on the display name — @rose pings rose.
    const aliases = new Map();
    for (const id of seats)
    {
        const role = registry[id].role;
        const display = typeof role === "object" && role ? role.displayName : (typeof role === "string" ? role : null);
        if (display)
            aliases.set(String(display).toLowerCase(), id);
    }
    const mentioned = new Set();
    if (/@(everyone|all)\b/i.test(text))
        for (const id of seats)
            mentioned.add(id);
    for (const match of text.matchAll(/@([A-Za-z0-9_-]+)/g))
    {
        const name = match[1];
        if (seats.includes(name))
            mentioned.add(name);
        else if (aliases.has(name.toLowerCase()))
            mentioned.add(aliases.get(name.toLowerCase()));
    }
    // #room pings every member of that room — the bus equivalent of walking
    // the message over to where the people are.
    const rooms = await store.getRooms().catch(() => ({}));
    for (const match of text.matchAll(/#([A-Za-z0-9_-]+)/g))
        for (const member of rooms[match[1]]?.members ?? [])
            if (member !== human && registry[member])
                mentioned.add(member);
    const preview = text.length > 300 ? `${text.slice(0, 300)}…` : text;
    for (const id of mentioned)
    {
        try
        {
            await dm(id, `[PING] ${human} in #${room}: ${preview}`);
        }
        catch (err)
        {
            console.error(`ping fanout to ${id} failed: ${err?.message ?? err}`);
            mentioned.delete(id);
        }
    }
    return [...mentioned];
}

// ---------- views ----------

async function roomList()
{
    const registry = await store.getRooms();
    const ret = [];
    for (const [name, meta] of Object.entries(registry))
    {
        const file = store.roomFile(name);
        const entries = await store.readJsonl(file);
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

async function history(limit)
{
    const rooms = await roomList();
    const all = [];
    for (const room of rooms)
        for (const entry of await store.readJsonl(store.roomFile(room.name)))
            all.push({ ...entry, stream: "room", room: entry.room ?? room.name });
    const inbox = await store.readJsonl(store.inboxFile(human));
    for (const entry of inbox)
        all.push({ ...entry, stream: "dm" });
    all.sort((a, b) => a.ts - b.ts);
    return all.slice(-limit);
}

function registryView()
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
    const now = Date.now();
    return Object.values(raw)
        .map((agent) => ({
            id: agent.agentId,
            role: agent.role ?? "",
            project: agent.project ?? "",
            lastHeartbeat: agent.lastHeartbeat ?? 0,
            online: now - (agent.lastHeartbeat ?? 0) < 5 * 60_000,
        }))
        .sort((a, b) => a.id.localeCompare(b.id));
}

function stateView()
{
    return {
        project,
        human,
        teamRoom,
        build: buildStamp(),
        startedAt,
        standDown: existsSync(standDownFile),
        recess: recessState(projectDir),
        agents: registryView(),
    };
}

// ---------- http ----------

function json(res, status, payload)
{
    const body = JSON.stringify(payload);
    res.writeHead(status, { "content-type": "application/json", "content-length": Buffer.byteLength(body) });
    res.end(body);
}

function readBody(req)
{
    return new Promise((resolve, reject) =>
    {
        let size = 0;
        const chunks = [];
        req.on("data", (chunk) =>
        {
            size += chunk.length;
            if (size > 256 * 1024)
            {
                reject(new Error("body too large"));
                req.destroy();
                return;
            }
            chunks.push(chunk);
        });
        req.on("end", () =>
        {
            try
            {
                resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {});
            }
            catch (err)
            {
                reject(err);
            }
        });
        req.on("error", reject);
    });
}

const types = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8" };


const server = createServer(async (req, res) =>
{
    const url = new URL(req.url, `http://${req.headers.host ?? host}`);
    try
    {
        if (req.method === "GET" && url.pathname === "/api/state")
            return json(res, 200, { ...stateView(), rooms: await roomList(), messages: await history(400) });

        if (req.method === "GET" && url.pathname === "/api/stream")
        {
            res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" });
            res.write(`data: ${JSON.stringify({ type: "hello", human })}\n\n`);
            clients.add(res);
            req.on("close", () => clients.delete(res));
            return;
        }

        if (req.method === "POST" && url.pathname === "/api/say")
        {
            const body = await readBody(req);
            const text = String(body.text ?? "").trim();
            if (!text)
                return json(res, 400, { ok: false, error: "empty message" });
            // The pump is the only thing that emits messages: writing to the file
            // and broadcasting here too would double every line the user sends.
            // say() fans mentions out to the seats' inboxes itself and reports
            // who it pinged; doing it here as well would deliver every ping twice.
            const { entry, pinged } = await say(body.room ?? teamRoom, text, body.kind, body.inReplyTo);
            return json(res, 200, { ok: true, entry, pinged });
        }



        if (req.method === "POST" && url.pathname === "/api/dm")
        {
            const body = await readBody(req);
            const to = String(body.to ?? "").trim();
            const text = String(body.text ?? "").trim();
            if (!to || !text)
                return json(res, 400, { ok: false, error: "need a recipient and a message" });
            const entry = await dm(to, text, body.inReplyTo);
            return json(res, 200, { ok: true, entry });
        }

        if (req.method === "POST" && url.pathname === "/api/recess")
        {
            const body = await readBody(req);
            const note = String(body.note ?? "").trim();
            const result = body.action === "end"
                ? await endRecess(store, { projectDir, room: teamRoom, by: human, note })
                : await startRecess(store, { projectDir, room: teamRoom, by: human, note });
            if (!result.ok)
                return json(res, 409, result);
            broadcast({ type: "recess", state: recessState(projectDir) });
            return json(res, 200, { ok: true, recess: recessState(projectDir) });
        }

        if (req.method === "POST" && url.pathname === "/api/standdown")
        {
            const body = await readBody(req);
            if (body.active)
            {
                mkdirSync(path.dirname(standDownFile), { recursive: true });
                writeFileSync(standDownFile, `${new Date().toISOString()} — stand-down requested from the team chat by ${human}\n`, "utf8");
            }
            else if (existsSync(standDownFile))
                unlinkSync(standDownFile);
            broadcast({ type: "standdown", active: existsSync(standDownFile) });
            return json(res, 200, { ok: true, active: existsSync(standDownFile) });
        }

        const name = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
        const file = path.join(publicDir, path.basename(name));
        if (existsSync(file) && statSync(file).isFile())
        {
            const body = readFileSync(file);
            res.writeHead(200, {
                "content-type": types[path.extname(file)] ?? "application/octet-stream",
                "content-length": body.length,
                "cache-control": "no-cache",
            });
            return res.end(body);
        }

        json(res, 404, { ok: false, error: "not found" });
    }
    catch (err)
    {
        json(res, 500, { ok: false, error: String(err?.message ?? err) });
    }
});

function parseArgs(argv)
{
    const ret = {};
    for (let i = 0; i < argv.length; i++)
    {
        const match = /^--([^=]+)(?:=(.*))?$/.exec(argv[i]);
        if (match)
            ret[match[1]] = match[2] ?? argv[++i];
    }
    return ret;
}

await registerHuman();
setInterval(() => heartbeat().catch(() => { }), 30_000).unref();
setInterval(pump, 400);
// A data-frame heartbeat: half-open SSE connections only die on a failed
// write, so without a periodic frame a silently-dead client looks live
// forever. The client also uses these to detect a stalled stream.
setInterval(() => broadcast({ type: "ping", ts: Date.now() }), 15_000).unref();

server.listen(port, host, () =>
{
    console.log(`${project} team chat — http://${host}:${port}`);
    console.log(`  seat:    ${human}`);
    console.log(`  bus:     ${coordDir}`);
    console.log(`  room:    #${teamRoom}`);
    console.log(`  recess:  ${recessState(projectDir).active ? "open" : "closed"} (tools/coord-recess)`);
    console.log(`  tui:     tools/coord-chat`);
    console.log(`  release: tools/coord-web --stand-down  (or the button in the page)`);
});
