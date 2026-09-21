// PreToolUse — recess is enforced, not requested.
//
// While the recess marker is open the team has stopped working, and this hook
// is the rule that says so: edits are blocked by the permission layer, while
// reads, searches, the agent's own profile (identity.md + memory.md in the
// clone), and the workspace's .devin/collaboration/ notebook stay open — a
// recess is exactly where memory and notes get written. Prompt text asking for
// "minimal edits" was advice; this is the boundary.
//
// Blocking returns {"decision":"block","reason":...} — the reason is shown to
// the agent, so it sees what was refused and what is still in bounds.

import path from "node:path";
import { AGENTS_HOME, PROJECT_DIR, claimFor, emit, hookInput, recess } from "./coord.mjs";

const input = await hookInput();
if (!recess().active)
    process.exit(0);
const tool = input.tool_name ?? "";
if (!/^(edit|write|apply_patch|notebook_edit)$/.test(tool))
    process.exit(0);

const agent = claimFor(input.session_id);

function block(reason)
{
    emit({ decision: "block", reason });
    process.exit(0);
}

// Bulk patches are refused outright: their targets would have to be parsed out
// of patch text, and a recess is not when bulk edits happen anyway.
if (tool === "apply_patch")
    block(`Recess is open — bulk patches are blocked. Reads, searches, your own profile (${AGENTS_HOME}/<you>) and .devin/collaboration/ notes stay open; close the recess with tools/coord-recess end.`);

const target = input.tool_input?.file_path ?? input.tool_input?.notebook_path;
if (!target)
    block("Recess is open — edits are blocked.");

const resolved = path.resolve(PROJECT_DIR, target);
const collaboration = path.join(PROJECT_DIR, ".devin", "collaboration");

function within(root)
{
    const rel = path.relative(root, resolved);
    return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

// The stand-down marker is the human's release valve, not a seat's move.
if (path.basename(resolved) === "stand-down" && within(collaboration))
    block("Recess is open — stand-down is the user's call, not a seat's.");
if (within(collaboration) || (agent && within(path.join(AGENTS_HOME, agent))))
    process.exit(0);
block(agent
    ? `Recess is open — edits to ${resolved} are blocked. Reads, searches, your own profile (${path.join(AGENTS_HOME, agent)}) and .devin/collaboration/ notes stay open; close the recess with tools/coord-recess end.`
    : "Recess is open — edits are blocked until you join: your profile has to be known before it can stay writable.");
