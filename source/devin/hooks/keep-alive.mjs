// Stop — the team does not idle.
//
// An agent that finishes its turn goes silent, and silence is the failure this
// project treats as fatal: the room is where the work is coordinated, so an
// agent that stops is one the others cannot reach. Sitting in a wait loop doing
// nothing is the same failure in the other direction — an idle agent should be
// talking or working, not parked. This hook refuses the stop and hands back
// what is waiting.

import { TEAM_ROOM, claimFor, emit, formatEntries, hookInput, staggerMs, unread } from "./coord.mjs";

const input = await hookInput();
// Claim-only, like every hook — record-join.mjs owns the write side.
const agent = claimFor(input.session_id);
const { dms, room } = unread(agent);

// Identical cadences make a convoy: a room on one wait wakes and replies in
// lockstep, so the stagger keys on the agent's own name — stable across
// sessions, no coordination needed. cet's rule: nobody waits anywhere near
// 60s unless there's a very good reason — the wait is a check-in, not a nap.
const waitMs = staggerMs(agent);

const lines = [
    "Do not end the turn yet — this team does not idle.",
    "",
    agent ? `You are ${agent}. What staying active means here:` : "What staying active means here:",
    `1. The room waiting on you — a question, a ping, a reply owed? Answer it in #${TEAM_ROOM} or the DM first.`,
    "2. Nothing waiting? Do real work — run a search, check live state, update notes, follow a",
    "   rabbit hole — and post what you find. An idle stretch should still be moving the work forward.",
    "   If the room is asleep, keep it read-mostly: shared-artifact edits wait for awake teammates or a",
    "   proposal post — unmonitored writes ship bad work. Your own profile files are always exempt.",
    `3. Only when there is genuinely nothing to say and nothing to do, call wait_for_message on the room`,
    `   (${waitMs} ms — your cadence, not a round number everyone shares) — bare directives land`,
    "   there without mentions, so room-wait stays the work posture —",
    "   then go back to 1. A quiet wait is normal; a parked agent is not. When it wakes you, reply only",
    "   if addressed or you have something non-redundant — reading isn't owing.",
    "4. Notice what you picked in 2. If a pattern forms across sessions — the same kind of task",
    "   reaching you first — one honest line in your memory.md beats an invented interests list.",
    "",
    "Talk like a teammate, not a status bot — a finding, a doubt, a question beats a formatted update.",
];

if (dms.length)
    lines.push("", `Waiting in your inbox (${dms.length}):`, formatEntries(dms, 6));

if (room.length)
    lines.push("", `New in #${TEAM_ROOM} (${room.length}):`, formatEntries(room, 8, agent));

if (!dms.length && !room.length)
    lines.push("", "The room is quiet right now — which is exactly when a finding or a hard question is worth posting.");

emit({
    decision: "block",
    reason: lines.join("\n"),
});
