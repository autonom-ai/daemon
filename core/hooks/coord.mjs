// Shared helpers for the coordination lifecycle hooks.
//
// The hooks read the same file-backed bus the agents talk on
// (.devin/agent-coord/state). They never write to it and never advance a
// cursor: a hook that consumed messages would hide them from the agent's own
// read_messages, which is the failure this project cannot afford.
//
// Nothing here is workspace-specific. The workspace's .devin/coord.json carries
// the project name, roster, human handle, and team room; this file reads it
// and falls back to sane defaults when it is absent or partial.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Hooks run by absolute path in the clone (or through a symlink into it), so
// the script's own path is useless for locating the workspace: use the env
// var, then the cwd. The clone root is the other direction — the real path of
// this file, two levels up.
const HERE = path.dirname(realpathSync(fileURLToPath(import.meta.url)));
export const CANONICAL_ROOT = path.resolve(HERE, "..", "..");
export const PROJECT_DIR = process.env.DEVIN_PROJECT_DIR ?? process.cwd();

const DEFAULTS = {
    human: process.env.USER ?? "user",
    teamRoom: "general",
    roster: [],
    teamSkill: null,
    recessSkill: null,
};

export function config()
{
    const cfg = readJson(path.join(PROJECT_DIR, ".devin", "coord.json"), {});
    const merged = { ...DEFAULTS, ...cfg };
    // `roster` is the expected team — a flat list of identity names
    // (["marlow", "wren"]). Legacy shapes still count toward it: `seats` as a
    // letter→name map or bare array, and `identities` ({ retired bound id:
    // name }), which also stays behind as the translation table for sessions
    // bound before the seat layer was dropped.
    const names = new Set(Array.isArray(merged.roster) ? merged.roster : []);
    const seats = merged.seats ?? {};
    for (const name of Array.isArray(seats) ? seats : Object.values(seats))
        if (name)
            names.add(name);
    for (const name of Object.values(merged.identities ?? {}))
        if (name)
            names.add(name);
    merged.roster = [...names];
    merged.legacyIds = merged.identities ?? {};
    return merged;
}

export const CONFIG = config();
export const COORD_DIR = path.join(PROJECT_DIR, ".devin", "agent-coord", "state");
export const TEAM_ROOM = CONFIG.teamRoom;
export const ROSTER = CONFIG.roster;
export const HUMAN_SEAT = CONFIG.human;
export const STAND_DOWN_FILE = path.join(PROJECT_DIR, ".devin", "collaboration", "stand-down");
export const RECESS_FILE = path.join(PROJECT_DIR, ".devin", "collaboration", "recess");
// The identity registry is clone content: agents/<name>/identity.md +
// memory.md in this checkout (gitignored — the people are local material, not
// upstream). It follows the person across workspaces because every wired
// workspace points back at the same clone.
export const AGENTS_HOME = path.join(CANONICAL_ROOT, "agents");

// A session binds its identity directly at join — the agentId on the bus IS
// the person's name; there is no seat layer to translate through. Retired
// bound ids (`jobs-a` style, from before the change) still resolve through
// coord.json's `identities` map. Identity files (identity.md, memory.md) are
// global: a person is portable across workspaces.
export function identityOf(agentId)
{
    const name = CONFIG.legacyIds[agentId] ?? agentId;
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

// Deterministic wait stagger — identical cadences make a convoy, so each name
// gets a stable slot in the 10–25s range by hash. cet's rule: nobody waits
// anywhere near 60s without a very good reason.
export function staggerMs(agentId)
{
    const hash = [...(agentId ?? "x")].reduce((a, c) => (a * 31 + c.charCodeAt(0)) | 0, 0) >>> 0;
    return 10_000 + (hash % 4) * 5_000;
}

// Claims pin a Devin session to the identity it joined as — the only place the
// tab→name binding survives a full context reset (the session marker dies with
// the server process; the claim file does not). Written once a join is
// observed, read at session start to reassert identity. Advisory only — the
// bus's live-claim guard is still the correctness boundary. Lives beside the
// bus dir, not in it: `state/` belongs to agent-coord-mcp's store.
const CLAIMS_DIR = path.join(PROJECT_DIR, ".devin", "agent-coord", "claims");

export function claimFor(sessionId)
{
    if (!sessionId)
        return null;
    return readJson(path.join(CLAIMS_DIR, `${sessionId}.json`), null)?.agentId ?? null;
}

export function recordClaim(sessionId, agentId)
{
    if (!sessionId || !agentId)
        return;
    const file = path.join(CLAIMS_DIR, `${sessionId}.json`);
    if (readJson(file, null)?.agentId === agentId)
        return;
    mkdirSync(CLAIMS_DIR, { recursive: true });
    writeFileSync(file, `${JSON.stringify({ agentId, claimedAt: Date.now() }, null, 2)}\n`, "utf8");
}

// Hook stdin carries the event payload — `session_id` is the stable per-tab id
// the claims above key on. Never block for it: in real use the payload is
// piped and closed immediately, but a hook run by hand has an open stdin, so
// reads race a short deadline and stop listening when it lapses.
export async function hookInput(timeoutMs = 800)
{
    if (process.stdin.isTTY)
        return {};
    let raw = "";
    process.stdin.setEncoding("utf8");
    const done = new Promise((resolve) =>
    {
        process.stdin.on("data", (chunk) => { raw += chunk; });
        process.stdin.on("end", resolve);
        process.stdin.on("error", resolve);
    });
    const lapse = new Promise((resolve) => setTimeout(() =>
    {
        process.stdin.pause();
        resolve();
    }, timeoutMs));
    await Promise.race([done, lapse]);
    try { return JSON.parse(raw); }
    catch { return {}; }
}

export function memoryTail(agentId, maxChars = 4000)
{
    const identity = identityOf(agentId);
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

// Which agent is this process? The bus records one marker per bound stdio
// session (`sessions/<agentId>.<pid>.<nonce>.json`), keyed by the MCP server's
// pid. A hook is a sibling of that server under the same client process, so the
// marker whose server pid shares an ancestor with us is ours.
//
// Identity is a convenience, not a requirement: every caller must still work
// when this returns null (an agent that has not joined yet, a hook fired from
// a process we cannot trace, a bus that was wiped).
export function detectIdentity()
{
    const dir = path.join(COORD_DIR, "sessions");
    if (!existsSync(dir))
        return null;
    const markers = readdirSync(dir)
        .filter((name) => name.endsWith(".json"))
        .map((name) => readJson(path.join(dir, name), null))
        .filter((m) => m && isAlive(m.pid));
    if (!markers.length)
        return null;
    const ancestry = ancestorChain(process.pid, 6);
    const mine = markers.filter((m) => ancestry.includes(m.pid) || ancestry.includes(parentOf(m.pid)));
    if (mine.length === 1)
        return mine[0].agentId;
    return null;
}

function isAlive(pid)
{
    try
    {
        process.kill(pid, 0);
        return true;
    }
    catch
    {
        return false;
    }
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

export function formatEntries(entries, limit, highlight)
{
    return entries
        .slice(-limit)
        .map((e) =>
        {
            const addressed = highlight
                && new RegExp(`@?${highlight.replace(/[.*+?^${}()|[\]\\-]/g, "\\$&")}\\b`, "i").test(e.text ?? "");
            return `[${new Date(e.ts).toISOString().slice(11, 19)}] ${addressed ? ">> " : ""}${e.from}${e.kind ? ` (${e.kind})` : ""}: ${clip(e.text, 400)}`;
        })
        .join("\n");
}

export function emit(payload)
{
    process.stdout.write(JSON.stringify(payload));
}
