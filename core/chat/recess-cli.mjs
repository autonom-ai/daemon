#!/usr/bin/env node
// tools/coord-recess — call, close, or inspect the team's recess.

import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { endRecess, loadStore, recessState, startRecess } from "./recess.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const projectDir = process.env.DEVIN_PROJECT_DIR ?? path.resolve(here, "..", "..");
const [action = "status", ...rest] = process.argv.slice(2);
const note = rest.join(" ").trim();
const by = process.env.COORD_AGENT ?? process.env.COORD_SEAT ?? process.env.USER ?? "unknown";
const room = process.env.COORD_ROOM ?? "general";

const state = recessState(projectDir);

if (action === "status")
{
    if (!state.active)
        console.log("no recess open");
    else
        console.log(`recess open since ${new Date(state.startedAt).toLocaleString()} (called by ${state.by})\nnote: ${state.note || "(none)"}`);
    process.exit(0);
}

if (!["start", "end"].includes(action))
{
    console.error("usage: tools/coord-recess [status|start [note]|end [outcome]]");
    process.exit(2);
}

const store = await loadStore(projectDir);
const result = action === "start"
    ? await startRecess(store, { projectDir, room, by, note })
    : await endRecess(store, { projectDir, room, by, note });

if (!result.ok)
{
    console.error(`coord-recess: ${result.error}`);
    process.exit(1);
}

console.log(action === "start"
    ? `recess open — announced in #${room} as ${by}`
    : `recess closed — announced in #${room} as ${by}`);

// An agent calling this is an agent that should now be talking, not building.
const notes = path.join(projectDir, ".devin", "collaboration", "recess-notes.md");
if (action === "end" && existsSync(notes) && note)
    console.log(`remember: put the useful part of the discussion in ${path.relative(projectDir, notes)} if it is not there yet`);
