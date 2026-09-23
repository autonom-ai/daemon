// UserPromptSubmit — surface what happened on the bus while this tab was busy.
//
// Reads only. Cursors stay where the agent left them, so the same traffic is
// still waiting in read_messages; this is a nudge, not a delivery.

import { HUMAN_SEAT, TEAM_ROOM, claimFor, emit, formatEntries, hookInput, unread } from "./coord.mjs";

const input = await hookInput();
// Claim-only, like every hook — record-join.mjs owns the write side.
const agent = claimFor(input.session_id);
const { dms, room } = unread(agent);
const lines = [];

if (agent)
    lines.push(`You are ${agent}. Team room: #${TEAM_ROOM}.`);

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
