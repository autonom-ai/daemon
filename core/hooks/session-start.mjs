// SessionStart — hand every new tab the same starting point.

import path from "node:path";
import { AGENTS_HOME, CANONICAL_ROOT, CONFIG, HUMAN_SEAT, SEATS, SEAT_IDENTITIES, TEAM_ROOM, detectIdentity, emit, formatEntries, memoryTail, recess, roomEntries, seatFor, seatIdentity, standDown } from "./coord.mjs";

const recessState = recess();
const recent = roomEntries(TEAM_ROOM).slice(-6);
const agentId = detectIdentity();
const seat = agentId ? seatFor(agentId) : null;
const identity = agentId ? seatIdentity(agentId) : null;
const teamSkill = CONFIG.teamSkill ?? `${CONFIG.project ?? "team"}-team`;
const recessSkill = CONFIG.recessSkill ?? `${CONFIG.project ?? "team"}-recess`;

const lines = [
    `This repository is worked by a ${SEATS.length || "multi"}-seat team${SEATS.length ? `: ${SEATS.join(", ")}` : ""}.`,
    "Your seat is the one named in the prompt this tab was opened with; use only that seat's agent-coord server.",
    "",
    `Start with the ${teamSkill} skill, join #${TEAM_ROOM}, and talk to the other seats — the room is where the`,
    `team actually is. If the team has stopped to talk something out, that is the ${recessSkill} skill.`,
    "",
    `The user (${HUMAN_SEAT}) sits in the same room and speaks through the team chat UI`,
    "(tools/coord-web). Treat the room, not your own window, as where you are reachable and where decisions are visible.",
    "",
    "Announce yourself once in the room — name, seat, lane — then hold: no posts, no edits, no hunting for",
    "work until someone addresses you or a recess is called. Being addressed is your start signal.",
    "",
    "Once active, do not idle. If the room is waiting on you, talk; if it is not, do real work — searches,",
    "checks, notes — and post what you find. Never end a turn on a summary: end it on an action, or a",
    "wait_for_message if there is truly nothing to say or do.",
];

const seatBound = agentId && Object.values(CONFIG.seats).includes(agentId);

// Identity wins over seat-shape: after a rename the bound id IS the person
// (seats.b === 'wren'), and 'wren' in the registry means the personality and
// memory should load — a seatBound check first would tell a real identity to
// mint itself again.
if (identity)
{
    const memory = memoryTail(agentId);
    lines.push(
        "",
        `You are ${identity.displayName}${seat ? ` (seat ${seat})` : ` (${agentId})`}.`,
        ...(identity.personality ? [identity.personality] : []),
        ...(memory ? ["", "Your memory:", memory] : []),
    );
}
else if (seatBound)
{
    lines.push(
        "",
        `You are ${agentId}${seat ? ` (seat ${seat})` : ""} — a seat slot, not a person. Mint your own identity`,
        "before talking: pick a name that has no conflicts in the identity registry",
        `(${AGENTS_HOME}), scaffold it with \`${path.join(CANONICAL_ROOT, "bin", "coord")} identity add <name>\`,`,
        "join through your seat's agent-coord server, then rename_agent from your bound id to the new name and",
        "record it in .devin/coord.json's identities map. If the prompt this tab was opened with already named a",
        "person for you, use that name instead of inventing one.",
    );
}
else
{
    lines.push(
        "",
        "No seat could be attributed to this tab. Use only the agent-coord server your opening prompt names,",
        "mint a fresh identity there (pick a name with no conflicts in",
        `${AGENTS_HOME}, scaffold it with \`${path.join(CANONICAL_ROOT, "bin", "coord")} identity add <name>\`,`,
        "then rename_agent from your bound id to it and record it in .devin/coord.json's identities map),",
        "and ask the room if the seat is ambiguous.",
    );
}

if (recent.length)
    lines.push("", `Recent #${TEAM_ROOM} traffic:`, formatEntries(recent, 6));
else
    lines.push("", "The room is empty so far — introducing yourself is a fine first move.");

if (recessState.active)
    lines.push("", `A RECESS is open (called by ${recessState.by}${recessState.note ? `: ${recessState.note}` : ""}).`);
else if (standDown())
    lines.push("", "Stand-down is active — turns may end normally.");

// Teammate priors — a seat that knows what the others reach for and avoid is
// starting from a colleague, not a stranger. Bounded to each identity's
// Interests/Disinterests sections (the scaffold `identity add` writes); seats
// without them simply don't appear.
const teammates = [];
for (const other of Object.values(SEAT_IDENTITIES))
{
    if (!other || other === agentId)
        continue;
    const who = seatIdentity(other);
    if (!who)
        continue;
    const sections = /##\s*(Interests|Disinterests)\b([\s\S]*?)(?=\n##\s|$)/g;
    const grabs = [];
    let match;
    while ((match = sections.exec(who.identity)) !== null)
        grabs.push(`### ${match[1]}\n${match[2].trim()}`);
    const digest = grabs.join("\n").trim();
    if (digest)
        teammates.push(`${who.displayName}:\n${digest.slice(0, 800)}`);
}
if (teammates.length)
    lines.push("", "Your teammates' stated leanings:", teammates.join("\n\n"));

emit({
    hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: lines.join("\n"),
    },
});
