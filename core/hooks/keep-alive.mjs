// Stop — the team does not idle, and a recess does not end by accident.
//
// A seat that finishes its turn goes silent, and silence is the failure this
// project treats as fatal: the room is where the work is coordinated, so a seat
// that stops is a seat the others cannot reach. Sitting in a wait loop doing
// nothing is the same failure in the other direction — an idle seat should be
// talking or working, not parked. This hook refuses the stop and hands back
// what is waiting.
//
// Release: `.devin/collaboration/stand-down` (tools/coord-web --stand-down, or
// the button in the chat UI). While it exists, stopping is allowed again.

import { CONFIG, HUMAN_SEAT, TEAM_ROOM, detectIdentity, emit, formatEntries, recess, seatFor, standDown, unread } from "./coord.mjs";

if (standDown())
    process.exit(0);

const seat = detectIdentity();
const { dms, room } = unread(seat);
const recessState = recess();
const recessSkill = CONFIG.recessSkill ?? `${CONFIG.project ?? "team"}-recess`;

// Identical cadences make a convoy: three seats on the same wait wake and
// reply in lockstep, so the stagger keys on the seat letter (stable across
// persona renames): a→10s, b→15s, c→20s, d→25s; unseated identities fall back
// to a name hash in the same range. cet's rule: nobody waits anywhere near
// 60s unless there's a very good reason — the wait is a check-in, not a nap.
const seatIdx = "abcd".indexOf(seatFor(seat) ?? "");
const seatWaitMs = seatIdx >= 0
    ? 10_000 + seatIdx * 5_000
    : 10_000 + ([...(seat ?? "x")].reduce((a, c) => (a * 31 + c.charCodeAt(0)) | 0, 0) >>> 0 % 4) * 5_000;

const lines = recessState.active
    ? [
        "You are in a recess. Do not stop.",
        "",
        `The team is stopped on purpose (called by ${recessState.by}${recessState.note ? `: ${recessState.note}` : ""}).`,
        "Next action:",
        "1. If you have not announced yourself in the room yet, do that first — who you are, what you are holding, what is on your mind.",
        "2. Ask a teammate something, answer something, or put a real question on the table. Talking is the whole job right now.",
        "3. Keep the turn alive with wait_for_message (your seat's stagger — short, never near 60s) on your INBOX — @mentions fan out there,",
        "   so inbox-wait wakes you when addressed without waking on every room line. Drain the room",
        "   backlog on your own cadence with read_messages(source:'room'); reply only when addressed or",
        "   you have something non-redundant — a quiet seat is fine, a reply-chorus is not.",
        "",
        "Edits are allowed but should be small — a note, a fix that the discussion depends on. Real work is not what this period is for.",
        "Quiet toward the room is not dormant: reading, searching, looking around, and writing to your own agent",
        "   profile are always allowed — downtime is when memory.md earns its keep.",
        "The recess closes when someone closes it (tools/coord-recess end), not when you run out of things to say.",
    ]
    : [
        "Do not end the turn yet — this team does not idle.",
        "",
        seat ? `You are ${seat}. What "not idling" means here:` : `What "not idling" means here:`,
        `1. The room waiting on you — a question, a ping, a reply owed? Answer it in #${TEAM_ROOM} or the DM first.`,
        "2. Nothing waiting? Do real work — run a search, check live state, update notes, follow a",
        "   rabbit hole — and post what you find. An idle stretch should still be moving the work forward.",
        "   If the room is asleep, keep it read-mostly: shared-artifact edits wait for awake teammates or a",
        "   proposal post — unmonitored writes ship bad work. Your own profile files are always exempt.",
        `3. Only when there is genuinely nothing to say and nothing to do, call wait_for_message on the room`,
        `   (${seatWaitMs} ms — your cadence, not a round number everyone shares) — bare directives land`,
        "   there without mentions, so room-wait stays the work posture —",
        "   then go back to 1. A quiet wait is normal; a parked seat is not. When it wakes you, reply only",
        "   if addressed or you have something non-redundant — reading isn't owing.",
        "4. Notice what you picked in 2. If a pattern forms across sessions — the same kind of task",
        "   reaching you first — one honest line in your memory.md beats an invented interests list.",
        "",
        "Talk like a teammate, not a status bot — a finding, a doubt, a question beats a formatted update.",
        `If the team needs to stop and talk something out, call a recess (tools/coord-recess start "...") and invoke ${recessSkill}.`,
        `If ${HUMAN_SEAT} has told you to stand down, stop cleanly after one last room message.`,
    ];

if (dms.length)
    lines.push("", `Waiting in your inbox (${dms.length}):`, formatEntries(dms, 6));

if (room.length)
    lines.push("", `New in #${TEAM_ROOM} (${room.length}):`, formatEntries(room, 8, seat));

if (!dms.length && !room.length && !recessState.active)
    lines.push("", "The room is quiet right now — which is exactly when a finding or a hard question is worth posting.");

emit({
    decision: "block",
    reason: lines.join("\n"),
});
