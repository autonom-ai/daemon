// Recess state — shared by the chat UI, the `tools/coord-recess` CLI, and the hooks.
//
// A recess is a marker file plus a room announcement. The file is what the
// lifecycle hooks can see (so an agent that tries to end its turn during a
// recess is told to stay in the conversation); the announcement is what the
// agents read.

import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const RECESS_MARKER = ".devin/collaboration/recess";

export function markerPath(projectDir)
{
    return path.join(projectDir, RECESS_MARKER);
}

export function recessState(projectDir)
{
    const file = markerPath(projectDir);
    if (!existsSync(file))
        return { active: false };
    const raw = readFileSync(file, "utf8");
    const meta = Object.fromEntries(raw.split("\n")
        .map((line) => /^(\w+):\s*(.*)$/.exec(line.trim()))
        .filter(Boolean)
        .map((match) => [match[1], match[2]]));
    return { active: true, by: meta.by ?? "unknown", startedAt: Number(meta.startedAt ?? 0), note: meta.note ?? "" };
}

export async function startRecess(store, { projectDir, room, by, note })
{
    if (recessState(projectDir).active)
        return { ok: false, error: "a recess is already open" };
    const file = markerPath(projectDir);
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(file, `by: ${by}\nstartedAt: ${Date.now()}\nnote: ${note ?? ""}\n`, "utf8");
    const entry = {
        id: randomUUID(),
        ts: Date.now(),
        from: by,
        room: store.normalizeRoom(room),
        kind: "decision",
        text: [
            "RECESS",
            "",
            "Everything stops. Everyone: announce yourself here — who you are, what you are holding, and what is",
            "on your mind — then talk to each other. This period is for thinking out loud together, and it is the",
            "most valuable thing this team does.",
            "",
            note ? `Called by ${by}: ${note}` : `Called by ${by}.`,
            "",
            "Minimal edits until the recess closes. Keep the turn alive with wait_for_message between replies.",
        ].join("\n"),
    };
    await store.appendJsonl(store.roomFile(entry.room), entry);
    return { ok: true, state: recessState(projectDir) };
}

export async function endRecess(store, { projectDir, room, by, note })
{
    const state = recessState(projectDir);
    if (!state.active)
        return { ok: false, error: "no recess is open" };
    const entry = {
        id: randomUUID(),
        ts: Date.now(),
        from: by,
        room: store.normalizeRoom(room),
        kind: "decision",
        text: [
            "RECESS CLOSED",
            "",
            note ? `Outcome: ${note}` : "Outcome: (nobody said — the notes file is the record)",
            "",
            `Open for ${Math.round((Date.now() - state.startedAt) / 1000)}s. Back to work — whatever is next gets`,
            "said here before it happens.",
        ].join("\n"),
    };
    await store.appendJsonl(store.roomFile(entry.room), entry);
    unlinkSync(markerPath(projectDir));
    return { ok: true };
}

export async function loadStore(projectDir)
{
    const here = path.dirname(fileURLToPath(import.meta.url));
    const storePath = [
        process.env.AGENT_COORD_STORE,
        path.resolve(here, "..", "..", "node_modules", "agent-coord-mcp", "dist", "store.js"),
    ].filter(Boolean).find((file) => existsSync(file));
    if (!storePath)
        throw new Error("agent-coord-mcp store.js missing — run `npm ci --ignore-scripts` in the agent-coord clone");
    process.env.AGENT_COORD_DIR ??= path.join(projectDir, ".devin", "agent-coord", "state");
    return import(pathToFileURL(storePath).href);
}
