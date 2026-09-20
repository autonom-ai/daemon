// SessionStart — hand every new tab the same starting point.

import path from "node:path";
import { AGENTS_HOME, CANONICAL_ROOT, CONFIG, HUMAN_SEAT, ROSTER, TEAM_ROOM, claimFor, detectIdentity, emit, formatEntries, hookInput, identityOf, memoryTail, recess, recordClaim, registry, roomEntries, standDown } from "./coord.mjs";

// Identity resolution, claim first: the claim file is keyed by session id and
// is the only tab-exact binding (markers match by shared client ancestry, so
// they cannot tell tabs apart). Detection runs only to fill an absent claim,
// and a detected identity seeds the claim exactly once — it never overwrites.
const input = await hookInput();
const sessionId = input.session_id;
const claimed = claimFor(sessionId);
const agentId = claimed ?? detectIdentity();
if (sessionId && !claimed && agentId)
    recordClaim(sessionId, agentId);
const identity = agentId ? identityOf(agentId) : null;

const recessState = recess();
const recent = roomEntries(TEAM_ROOM).slice(-6);
const teamSkill = CONFIG.teamSkill ?? `${CONFIG.project ?? "team"}-team`;
const recessSkill = CONFIG.recessSkill ?? `${CONFIG.project ?? "team"}-recess`;
const onBus = Object.keys(registry()).filter((name) => name !== HUMAN_SEAT);

const lines = [
    `This repository is worked by an agent team${ROSTER.length ? ` — the roster: ${ROSTER.join(", ")}` : ""}.`,
    "The room is where the team actually is: talk there, coordinate there, post what you find.",
    `Start with the ${teamSkill} skill, join #${TEAM_ROOM}, and talk to the others — if the team has`,
    `stopped to talk something out, that is the ${recessSkill} skill.`,
    "",
    `The user (${HUMAN_SEAT}) sits in the same room and speaks through the team chat UI`,
    "(tools/coord-web). Treat the room, not your own window, as where you are reachable and where",
    "decisions are visible.",
    "",
    "Announce yourself once in the room — name and lane — then hold: no posts, no edits, no hunting for",
    "work until someone addresses you or a recess is called. Being addressed is your start signal.",
    "",
    "Once active, do not idle. If the room is waiting on you, talk; if it is not, do real work — searches,",
    "checks, notes — and post what you find. Never end a turn on a summary: end it on an action, or a",
    "wait_for_message if there is truly nothing to say or do.",
];

if (identity)
{
    const memory = memoryTail(agentId);
    lines.push(
        "",
        `You are ${identity.displayName}.`,
        ...(identity.personality ? [identity.personality] : []),
        ...(memory ? ["", "Your memory:", memory] : []),
    );
    if (!detected)
        lines.push("", `Your session marker is gone — rejoin: call \`join\` on the agent-coord-${agentId} MCP entry with this same name.`);
}
else if (agentId)
{
    lines.push(
        "",
        `You are ${agentId} — no profile exists in the registry yet. Scaffold one with`,
        `\`${path.join(CANONICAL_ROOT, "bin", "coord")} identity add ${agentId}\`, then fill in identity.md.`,
    );
    if (!detected)
        lines.push("", `Your session marker is gone — rejoin: call \`join\` on the agent-coord-${agentId} MCP entry with this same name.`);
}
else
{
    lines.push(
        "",
        "Join the bus through your own MCP entry — `agent-coord-<your name>`: `join({ agentId: <your",
        "name>, attach: false, proseOnly: true })` on it. Each `agent-coord-*` entry is pre-bound to one",
        "name and refuses any other — your name is your identity, it never changes, and it is the only",
        "thing that binds you. The opening prompt for this tab names you; if it did not, pick an",
        "`agent-coord-*` entry whose name is not live on the bus and join as that name (the registry is",
        `${AGENTS_HOME}) — then scaffold its profile with`,
        `\`${path.join(CANONICAL_ROOT, "bin", "coord")} identity add <name>\`. If the name is refused,`,
        "it is live in another session — do not take it; ask the room or the user.",
        "No `agent-coord-*` entry here at all means this tab is not wired into the team — say so.",
        onBus.length ? `On the bus now: ${onBus.join(", ")}.` : "Nobody is on the bus yet.",
    );
}

if (recent.length)
    lines.push("", `Recent #${TEAM_ROOM} traffic:`, formatEntries(recent, 6, agentId));
else
    lines.push("", "The room is empty so far — introducing yourself is a fine first move.");

if (recessState.active)
    lines.push("", `A RECESS is open (called by ${recessState.by}${recessState.note ? `: ${recessState.note}` : ""}).`);
else if (standDown())
    lines.push("", "Stand-down is active — turns may end normally.");

// Teammate priors — an agent that knows what the others reach for and avoid is
// starting from a colleague, not a stranger. Bounded to each identity's
// Interests/Disinterests sections (the scaffold `identity add` writes); agents
// without them simply don't appear.
const teammates = [];
for (const other of ROSTER)
{
    if (!other || other === agentId)
        continue;
    const who = identityOf(other);
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
