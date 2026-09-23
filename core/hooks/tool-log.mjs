// PostToolUse — a rolling one-hour window of tool calls, kept in the agent's
// own profile.
//
// Every completed tool call appends one line to
// agents/<name>/tool-calls.jsonl and drops entries older than an hour on the
// same pass — the file is the window, so there is no timer, no cron, and no
// separate pruning step. Calls from a session that has not joined yet land in
// the bus's tool-calls-anon.jsonl instead: nothing escapes the log, but a
// profile only ever carries its owner's calls.
//
// Usage review (credits, debugging, "what was this tab doing") reads the file
// directly — it is already the last hour, no date math needed.
//
// This hook observes only: it never blocks, never emits, and exits quietly on
// any failure — a logging bug must not become a tool failure.

import { appendFileSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import { AGENTS_HOME, COORD_DIR, claimFor, clip, hookInput } from "./coord.mjs";

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
    const file = agent
        ? path.join(AGENTS_HOME, agent, "tool-calls.jsonl")
        : path.join(COORD_DIR, "tool-calls-anon.jsonl");
    const now = Date.now();
    const entry = {
        ts: now,
        tool,
        ...(argOf(input) !== undefined ? { arg: argOf(input) } : {}),
        ...(input.tool_response?.success === false ? { ok: false } : {}),
    };

    // Read-filter-rewrite keeps the file self-pruning: it can never grow past
    // one hour of calls no matter how long a session runs. Temp-then-rename so
    // a crash mid-write cannot truncate the window.
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
    mkdirSync(path.dirname(file), { recursive: true });
    const tmp = `${file}.${process.pid}.tmp`;
    writeFileSync(tmp, kept.length ? `${kept.join("\n")}\n` : "", "utf8");
    renameSync(tmp, file);
    appendFileSync(file, `${JSON.stringify(entry)}\n`, "utf8");
}
catch { }

process.exit(0);
