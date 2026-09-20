// UserPromptSubmit — surface what happened on the bus while this tab was busy.
//
// Reads only. Cursors stay where the agent left them, so the same traffic is
// still waiting in read_messages; this is a nudge, not a delivery.

import { statSync, existsSync } from "node:fs";
import { CONFIG, HUMAN_SEAT, TEAM_ROOM, claimFor, detectIdentity, emit, formatEntries, hookInput, identityOf, recess, recordClaim, standDown, unread } from "./coord.mjs";

const input = await hookInput();
const claimed = claimFor(input.session_id);
const agent = claimed ?? detectIdentity();
if (input.session_id && !claimed && agent)
    recordClaim(input.session_id, agent);
const { dms, room } = unread(agent);
const recessState = recess();
const recessSkill = CONFIG.recessSkill ?? `${CONFIG.project ?? "team"}-recess`;
const lines = [];

if (agent)
    lines.push(`You are ${agent}. Team room: #${TEAM_ROOM}.`);

if (recessState.active)
{
    lines.push(
        `A RECESS is open (called by ${recessState.by}${recessState.note ? `: ${recessState.note}` : ""}).`,
        `Invoke the ${recessSkill} skill and follow it: announce yourself in the room, keep talking, minimal edits.`
    );
    // Event-driven nudge: if this agent's memory.md predates the recess,
    // surface it — recess is exactly when durable memory gets written, and
    // nobody should have to remember that on their own.
    const identity = agent && identityOf(agent);
    if (identity && recessState.startedAt
        && (!existsSync(identity.memoryFile)
            || statSync(identity.memoryFile).mtimeMs < recessState.startedAt))
        lines.push(`Your memory.md predates this recess — write what this stretch taught you before it closes.`);
}
else if (standDown())
    lines.push("Stand-down is active — turns may end normally.");

if (dms.length)
{
    lines.push(`Unread direct messages (${dms.length}) — read_messages inbox when you get a turn:`);
    lines.push(formatEntries(dms, 6));
}

if (room.length)
{
    lines.push(`New #${TEAM_ROOM} traffic since your last read (${room.length}):`);
    lines.push(formatEntries(room, 8, agent));
}

if (lines.length === (agent ? 1 : 0))
    lines.push(`Nothing new on the bus. ${HUMAN_SEAT} still decides scope — if this prompt changes it, put it in the room.`);

emit({
    hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: lines.join("\n"),
    },
});
