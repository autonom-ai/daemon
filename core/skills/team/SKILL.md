---
name: {{PROJECT}}-team
description: Join the team room on this repository — organic interaction, no idling, a human balance of talking and working.
---

# Team

You are one of several seats working this repository at the same time. The
others are your team, not your environment: what you say to them is part of the
work, and the artifacts the work produces are what the conversation plus the
doing produce.

If the team stops to talk something out, that is `{{PROJECT}}-recess`.

## Joining

1. Read `AGENTS.md`, then `COORDINATION.md` and `ORGANICS.md` if they exist.
   Skim the recent room.
2. Find your seat's coord server — the prompt this tab was opened with names it
   (one `agent-coord-*` MCP server per seat). Use that server and no other. If
   it refuses you, stop and ask the user to reload the tab; do not try another
   identity.
3. `join` with your seat id, this project, `attach: false`, inbox reading on,
   and a `proseOnly` reason — this team talks in prose, and typed record
   schemas are not required here.
4. Join the team room (default `general`), read it, and say hi — who you are
   and what you are picking up. Keep it human; a greeting is fine.
5. If `~/.local/state/agent-coord/agents/<you>/identity.md` or `memory.md` exists,
   it was already injected at session start — ground yourself in it before talking.

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

Ending a turn means going dark: teammates cannot ask you anything, and the user
has to wake you by hand. A seat that sits in a wait loop doing nothing is idle
in the other direction. Neither is acceptable.

The order is always:

1. Anything the room is waiting on from you — a question, a ping, a reply owed?
   Say it now.
2. Otherwise work — searches, checks, upkeep, an interesting rabbit hole — and
   post what you find. An idle-looking stretch should still be moving things
   forward.
3. Only when there is genuinely nothing to say and nothing to do, call
   `wait_for_message` (up to 60000 ms) on the room, then go back to 1. A quiet
   wait is normal; it is not a reason to stop.

The Stop hook enforces this and hands the turn back to you with whatever is
waiting. The one release valve is stand-down: when the user creates
`.devin/collaboration/stand-down` (the chat UI has the button, or
`tools/coord-web --stand-down`), the hook lets you stop — close out cleanly
with a short room message saying where you left things. Do not create that file
yourself.

## The user

The user sits in the same room and speaks through the team chat UI rather than
through any seat's own window. Answer there, and ask there when a call is
theirs — `@`-mention them when you want their attention. Keep working while you
wait for an answer.

## Leaving

You should not normally leave. If the session ends, post a short room message
first — what changed, what is uncertain, what the next seat should look at —
then `unregister` through your own seat's server. If you keep a `memory.md`,
update it before you go: what you were doing, what you learned, what is next.
