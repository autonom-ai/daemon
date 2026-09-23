// PostToolUse — a rolling one-hour window of tool calls, kept in the agent's
// own profile.
//
// Every completed tool call from a joined session appends one line to
// agents/<name>/tool-calls.jsonl and drops entries older than an hour on the
// same pass — the file is the window, so there is no timer, no cron, and no
// separate pruning step. Calls from sessions without a recorded identity are
// ignored; no central or anonymous log is written.
//
// Usage review (credits, debugging, "what was this tab doing") reads the file
// directly — it is already the last hour, no date math needed.
//
// This hook observes only: it never blocks, never emits, and exits quietly on
// any failure — a logging bug must not become a tool failure.

import { appendFileSync, mkdirSync, readFileSync, renameSync, rmdirSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { AGENTS_HOME, claimFor, clip, hookInput } from "./coord.mjs";

const WINDOW_MS = 3600_000;

// One small identifying field per call — enough to say what the call touched
// without copying payloads. Reads stay one-field; anything richer belongs in
// the transcript, not here.
function argOf(input)
{
    const arg = input.tool_input ?? {};
    const picked = arg.file_path ?? arg.notebook_path ?? arg.command ?? arg.pattern
        ?? arg.url ?? arg.room ?? arg.query ?? arg.server_name;
    return picked === undefined ? undefined : clip(String(picked), 160);
}

try
{
    const input = await hookInput();
    const tool = input.tool_name ?? "";
    if (!tool)
        process.exit(0);
    const agent = claimFor(input.session_id);
    if (!agent)
        process.exit(0);
    const file = path.join(AGENTS_HOME, agent, "tool-calls.jsonl");
    const now = Date.now();
    const entry = {
        ts: now,
        tool,
        ...(argOf(input) !== undefined ? { arg: argOf(input) } : {}),
        ...(input.tool_response?.success === false ? { ok: false } : {}),
    };

    // Read-filter-rewrite keeps the file self-pruning: it can never grow past
    // one hour of calls no matter how long a session runs. Two hooks can fire
    // concurrently for the same agent (parallel tool calls), so the prune runs
    // inside a mkdir lock — a contended prune is skipped rather than raced,
    // because a dropped line matters more than a stale one surviving an hour.
    mkdirSync(path.dirname(file), { recursive: true });
    const lock = `${file}.lock`;
    let locked = false;
    try
    {
        mkdirSync(lock);
        locked = true;
    }
    catch
    {
        // A crashed hook can strand its lock; anything older than 30s is dead.
        try
        {
            if (now - statSync(lock).mtimeMs > 30_000)
            {
                rmdirSync(lock);
                mkdirSync(lock);
                locked = true;
            }
        }
        catch { }
    }
    if (locked)
    {
        const kept = [];
        try
        {
            for (const line of readFileSync(file, "utf8").split("\n"))
            {
                if (!line.trim())
                    continue;
                try
                {
                    const e = JSON.parse(line);
                    if (now - (e.ts ?? 0) <= WINDOW_MS)
                        kept.push(line);
                }
                catch { }
            }
        }
        catch { }
        // Temp-then-rename so a crash mid-write cannot truncate the window.
        const tmp = `${file}.${process.pid}.tmp`;
        writeFileSync(tmp, kept.length ? `${kept.join("\n")}\n` : "", "utf8");
        renameSync(tmp, file);
    }
    try
    {
        appendFileSync(file, `${JSON.stringify(entry)}\n`, "utf8");
    }
    finally
    {
        if (locked)
            try { rmdirSync(lock); } catch { }
    }
}
catch { }

process.exit(0);
