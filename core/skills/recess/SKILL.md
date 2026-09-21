---
name: {{PROJECT}}-recess
description: Stop work, gather in the team room, and talk — the team's open discussion period.
argument-hint: "Start a recess | Join the recess already open | Close the recess"
---

# Recess

A recess is the team stopping on purpose: tools down, everyone in the room,
talking. Not a meeting with a form to fill in — the period where the team
thinks out loud together instead of each agent working alone.

**Everything else stops.** Whatever you were mid-way through can wait; if it
genuinely cannot, say so in the room and let the others decide. Stops means
outward work — and it is enforced, not asked for: the permission hook blocks
workspace edits while the recess is open. Reading, searching, writing your own
profile or memory files, and `.devin/collaboration/` notes stay in-bounds the
whole time; a recess is often exactly where a memory note gets written.

## Opening one

Anyone can call a recess, and so can the user (the Team Room view's call recess
button does the same thing):

```sh
tools/coord-recess start "what we should talk about"
```

That writes the marker the lifecycle hooks read and announces the recess in the
team room. Invoke this skill once you see the announcement, or when the team
agrees it is time.

## What you do

- Announce yourself in the room — who you are, what you were holding, what is
  on your mind. If you arrived after the recess opened, announce anyway; an agent
  that is present but silent is not present.
- Then talk. What happened lately, what surprised you, what is bothering you,
  what the project should do next. Disagreement is the useful part — the good
  recess is the one where someone's assumption does not survive contact with
  the others.
- Keep the turn alive with `wait_for_message` (your stagger — short,
  never near 60s) between replies. A
  quiet wait is normal and is not a reason to stop. You do not owe a reply to
  every message — if a teammate already said your piece, let it stand; talk
  when you have something the room doesn't.
- Edits to the workspace are blocked while the recess is open — the hook says
  no, so do not spend the period trying. A note in `.devin/collaboration/` and
  your own profile files still write. Real work is not what this period is for.
- Anything the user should decide — @-mention them in the room and keep the
  conversation going while you wait.

## Closing it

When the room has landed somewhere:

1. Put the durable part in `.devin/collaboration/recess-notes.md` — brief and
   freeform beats complete and formal.
2. Close it:

```sh
tools/coord-recess end "what came out of it"
```

That posts the outcome to the room and lifts the marker, and everyone goes back
to work.

A recess that produced no change is a legitimate outcome — but say that out
loud, and say why nothing needed to change.
