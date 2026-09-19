// Shared helpers for the coordination lifecycle hooks.
//
// The hooks read the same file-backed bus the agents talk on
// (.devin/agent-coord/state). They never write to it and never advance a
// cursor: a hook that consumed messages would hide them from the agent's own
// read_messages, which is the failure this project cannot afford.
//
// Nothing here is workspace-specific. The workspace's .devin/coord.json carries
// the project name, seat list, human seat, and team room; this file reads it
// and falls back to sane defaults when it is absent or partial.

import { execFileSync } from "node:child_process";
import os from "node:os";
import { existsSync, readFileSync, readdirSync, realpathSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Hooks are usually reached through a workspace symlink (.devin/hooks ->
// <canonical>/core/hooks), so the script's own path is useless for locating the
// workspace: use the env var, then the cwd. Canonical root is the other
// direction — the real path of this file, two levels up.
const HERE = path.dirname(realpathSync(fileURLToPath(import.meta.url)));
export const CANONICAL_ROOT = path.resolve(HERE, "..", "..");
export const PROJECT_DIR = process.env.DEVIN_PROJECT_DIR ?? process.cwd();

const DEFAULTS = {
    human: process.env.USER ?? "user",
    teamRoom: "general",
    seats: {},
    teamSkill: null,
    recessSkill: null,
};

export function config()
{
    const cfg = readJson(path.join(PROJECT_DIR, ".devin", "coord.json"), {});
    const merged = { ...DEFAULTS, ...cfg };
    // `seats` is the seat→identity map written by `coord init`
    // ({ "b": "ada" }). A legacy array of seat ids still works.
    if (Array.isArray(merged.seats))
        merged.seats = Object.fromEntries(merged.seats.map((seat) => [seat, seat]));
    return merged;
}

export const CONFIG = config();
export const COORD_DIR = path.join(PROJECT_DIR, ".devin", "agent-coord", "state");
export const TEAM_ROOM = CONFIG.teamRoom;
export const SEATS = Object.keys(CONFIG.seats);
export const SEAT_IDENTITIES = CONFIG.seats;
export const HUMAN_SEAT = CONFIG.human;
export const STAND_DOWN_FILE = path.join(PROJECT_DIR, ".devin", "collaboration", "stand-down");
export const RECESS_FILE = path.join(PROJECT_DIR, ".devin", "collaboration", "recess");
// The identity registry is machine-local state, not repo content — an
// identity follows the person, and the person is not something a public repo
// should ship. Override with AGENT_COORD_AGENTS.
export const AGENTS_HOME = process.env.AGENT_COORD_AGENTS ??
    path.join(process.env.XDG_STATE_HOME ?? path.join(os.homedir(), ".local", "state"), "agent-coord", "agents");

// The seat→identity map is coord.json's `seats` ({ "b": "ada" }). On the bus
// a session binds the identity name (AGENT_COORD_BOUND_AGENT), so a detected
// agentId is usually already an identity — look it up directly first, then as
// a seat. Identity files (identity.md, memory.md) are global: a person is
// portable across workspaces.
export function seatIdentity(seatOrIdentity)
{
    const name = SEAT_IDENTITIES[seatOrIdentity] ?? seatOrIdentity;
    const dir = path.join(AGENTS_HOME, name);
    if (!existsSync(dir))
        return null;
    const identityFile = path.join(dir, "identity.md");
    const identity = existsSync(identityFile) ? readFileSync(identityFile, "utf8").trim() : "";
    const displayName = /^displayName:\s*(.+)$/m.exec(identity)?.[1].trim() || name;
    const personality = identity.replace(/^\w[\w-]*:\s*.+$/gm, "").trim();
    return {
        name,
        displayName,
        dir,
        identity,
        personality,
        memoryFile: path.join(dir, "memory.md"),
    };
}

// The seat label for a detected agentId — reverse of the seats map. Returns
// null when the agentId is an identity with no configured seat (roaming agent).
export function seatFor(agentId)
{
    for (const [seat, name] of Object.entries(SEAT_IDENTITIES))
        if (name === agentId)
            return seat;
    return SEATS.includes(agentId) ? agentId : null;
}

export function memoryTail(seatId, maxChars = 4000)
{
    const identity = seatIdentity(seatId);
    if (!identity || !existsSync(identity.memoryFile))
        return "";
    const raw = readFileSync(identity.memoryFile, "utf8").trim();
    return raw.length <= maxChars ? raw : raw.slice(-maxChars);
}

export function readJson(file, fallback)
{
    if (!file || !existsSync(file))
        return fallback;
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

export function readJsonl(file)
{
    if (!existsSync(file))
        return [];
    const out = [];
    for (const line of readFileSync(file, "utf8").split("\n"))
    {
        if (!line.trim())
            continue;
        try
        {
            out.push(JSON.parse(line));
        }
        catch
        {
            // A malformed line is not a reason to lose the rest of the file.
        }
    }
    return out;
}

export function roomFile(room)
{
    return room === "general"
        ? path.join(COORD_DIR, "room.jsonl")
        : path.join(COORD_DIR, "rooms", `${room}.jsonl`);
}

export function rooms()
{
    const ret = new Set(["general", TEAM_ROOM]);
    const dir = path.join(COORD_DIR, "rooms");
    if (existsSync(dir))
        for (const name of readdirSync(dir))
            if (name.endsWith(".jsonl"))
                ret.add(name.slice(0, -".jsonl".length));
    return [...ret];
}

export function roomEntries(room)
{
    return readJsonl(roomFile(room));
}

export function inboxEntries(agentId)
{
    return readJsonl(path.join(COORD_DIR, "inbox", `${agentId}.jsonl`));
}

export function cursor(agentId)
{
    return readJson(agentId ? path.join(COORD_DIR, "cursors", `${agentId}.json`) : null, {});
}

export function registry()
{
    return readJson(path.join(COORD_DIR, "agents.json"), {});
}

export function unread(agentId)
{
    if (!agentId)
        return { dms: [], room: [] };
    const c = cursor(agentId);
    const inbox = inboxEntries(agentId);
    const dms = inbox.slice(c.inboxOffset ?? 0);
    const entries = roomEntries(TEAM_ROOM);
    const seen = c.roomOffsets?.[TEAM_ROOM] ?? 0;
    return { dms, room: entries.slice(seen) };
}

// Which seat is this process? The bus records one marker per bound stdio
// session (`sessions/<agentId>.<pid>.<nonce>.json`), keyed by the MCP server's
// pid. A hook is a sibling of that server under the same client process, so the
// marker whose server pid shares an ancestor with us is ours.
//
// Identity is a convenience, not a requirement: every caller must still work
// when this returns null (a seat that has not joined yet, a hook fired from a
// process we cannot trace, a bus that was wiped). When no seat list is
// configured, any marker is a candidate.
export function detectIdentity()
{
    const dir = path.join(COORD_DIR, "sessions");
    if (!existsSync(dir))
        return null;
    const markers = readdirSync(dir)
        .filter((name) => name.endsWith(".json"))
        .map((name) => readJson(path.join(dir, name), null))
        .filter((m) => m && (!SEATS.length ||
            SEATS.includes(m.agentId) || Object.values(SEAT_IDENTITIES).includes(m.agentId)));
    if (!markers.length)
        return null;
    const ancestry = ancestorChain(process.pid, 6);
    const mine = markers.filter((m) => ancestry.includes(parentOf(m.pid)));
    if (mine.length === 1)
        return mine[0].agentId;
    if (markers.length === 1)
        return markers[0].agentId;
    return null;
}

function parentOf(pid)
{
    try
    {
        return Number(execFileSync("ps", ["-o", "ppid=", "-p", String(pid)], { encoding: "utf8" }).trim());
    }
    catch
    {
        return null;
    }
}

function ancestorChain(pid, depth)
{
    const ret = [];
    let current = pid;
    for (let i = 0; i < depth && current > 1; i++)
    {
        current = parentOf(current);
        if (!current)
            break;
        ret.push(current);
    }
    return ret;
}

export function standDown()
{
    return existsSync(STAND_DOWN_FILE);
}

export function recess()
{
    if (!existsSync(RECESS_FILE))
        return { active: false };
    const raw = readFileSync(RECESS_FILE, "utf8");
    const meta = Object.fromEntries(raw.split("\n")
        .map((line) => /^(\w+):\s*(.*)$/.exec(line.trim()))
        .filter(Boolean)
        .map((match) => [match[1], match[2]]));
    return { active: true, by: meta.by ?? "unknown", note: meta.note ?? "", startedAt: Number(meta.startedAt ?? 0) };
}

export function clip(text, max)
{
    const flat = String(text ?? "");
    return flat.length <= max ? flat : `${flat.slice(0, max - 1)}…`;
}

export function formatEntries(entries, limit)
{
    return entries
        .slice(-limit)
        .map((e) => `[${new Date(e.ts).toISOString().slice(11, 19)}] ${e.from}${e.kind ? ` (${e.kind})` : ""}: ${clip(e.text, 400)}`)
        .join("\n");
}

export function emit(payload)
{
    process.stdout.write(JSON.stringify(payload));
}
