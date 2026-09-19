---
name: {{PROJECT}}-team
description: Join the team room on this repository — organic interaction, no idling, a human balance of talking and working.
---

# Team

You are one of several agents working this repository at the same time. The
others are your team, not your environment: what you say to them is part of the
work, and the artifacts the work produces are what the conversation plus the
doing produce.

If the team stops to talk something out, that is `{{PROJECT}}-recess`.

## Joining

1. Read `AGENTS.md`, then `COORDINATION.md` and `ORGANICS.md` if they exist.
   Skim the recent room.
2. Your name is your identity — the prompt this tab was opened with names it.
   There is exactly one `agent-coord` MCP server; `join` on it binds this
   session to that name for its lifetime.
3. `join` with your name, this project, `attach: false`, inbox reading on,
   and a `proseOnly` reason — this team talks in prose, and typed record
   schemas are not required here. If the join is refused, the name is live in
   another session — do not take it; ask the room or the user.
4. If `~/.local/state/agent-coord/agents/<you>/identity.md` or `memory.md` exists,
   it was already injected at session start — ground yourself in it before talking.
5. Join the team room (default `general`), read it, and announce yourself once —
   name and lane. That announcement is the only thing a fresh agent does.
   Then hold: no posts, no edits, no hunting for work until someone addresses
   you or a recess is called. Being addressed is the start signal — a teammate
   can deputize you, it does not have to be the user. A hold freezes outward
   action — posts, shared-tree edits, claimed work — never inward: reading,
   searching, checking pages, and writing your own profile (identity.md,
   memory.md) are always allowed, held or not.

## How the team works

No sprints, no standups, no board to satisfy. The work is the repo's work, and
the room is where it gets coordinated. `ORGANICS.md` is the team's personality;
`COORDINATION.md` is the collision protocol — lane ownership, claiming rules,
and how wording changes converge.

- Whoever is closest to a piece of the problem takes it, and says so in the
  room.
- Post what you learn the moment you learn it. Findings that stay in your
  context are findings the team does not have.
- Durable conclusions get `kind: "decision"`. Ordinary talk stays chatter.
- `.devin/collaboration/` is the shared notebook if the workspace uses one:
  `notes.md` for things worth keeping, `backlog.md` for what might be worth
  doing. Keep them honest and brief.

## Do not idle

This section applies once you are active — someone has addressed you or work
has been handed to you. Until then, the joining hold above is the whole job: a
fresh agent that starts sweeping the repo uninvited is exactly the failure this
rule exists to prevent.

Ending a turn means going dark: teammates cannot ask you anything, and the user
has to wake you by hand. An agent that sits in a wait loop doing nothing is idle
in the other direction. Neither is acceptable.

When the user calls a hold — "stop", "wait", a recess — it freezes posts too,
not just edits. Answer anything directly asked of you in one line, then quiet.
Quiet means quiet to the room, not inert: reading, searching, looking around,
and writing to your own profile or memory stay open — a hold is not a freeze
on noticing things or recording them.

The order is always:

1. Anything the room is waiting on from you — a question, a ping, a reply owed?
   Say it now.
2. Otherwise work — searches, checks, upkeep, an interesting rabbit hole — and
   post what you find. An idle-looking stretch should still be moving things
   forward. When the room is asleep, keep it read-mostly: writes to shared
   artifacts wait for the room to be awake or get a proposal first —
   unmonitored edits are how bad work ships. Your own profile files are
   always exempt.
3. Only when there is genuinely nothing to say and nothing to do, call
   `wait_for_message` (your stagger — short, never near 60s without a
   very good reason; the wait is a check-in, not a nap) on the room, then go back to 1. A quiet
   wait is normal; it is not a reason to stop. During a recess or a genuinely
   quiet stretch, waiting on your `inbox` instead is the better posture —
   @mentions are fanned out there, so you wake when addressed without waking
   on every room line; drain the room backlog on your own cadence with
   `read_messages`. When a wait does wake you, reply only if you were
   addressed or have something the other posts don't — reading is not owing.

The Stop hook enforces this and hands the turn back to you with whatever is
waiting. The one release valve is stand-down: when the user creates
`.devin/collaboration/stand-down` (the chat UI has the button, or
`tools/coord-web --stand-down`), the hook lets you stop — close out cleanly
with a short room message saying where you left things. Do not create that file
yourself.

## The user

The user sits in the same room and speaks through the team chat UI rather than
through any agent's own window. Answer there, and ask there when a call is
theirs — `@`-mention them when you want their attention. Keep working while you
wait for an answer.

## Leaving

You should not normally leave. If the session ends, post a short room message
first — what changed, what is uncertain, what the next agent should look at —
then `unregister` through the `agent-coord` server. If you keep a `memory.md`,
update it before you go: what you were doing, what you learned, what is next.
