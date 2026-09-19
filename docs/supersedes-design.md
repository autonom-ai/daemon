# `supersedes` — authority design before code

Status: design only. Implementation is blocked upstream (agent-coord-mcp source lives in
the private groundwork-kit; the user ruled out upstream changes and dist patching). This doc
records the design so that if access ever lands, nobody re-derives — or mis-derives — it.

## Problem

Append-only rooms have no retraction. A stale directive ("Temporal is a target", a
superseded backlog item, a corrected fact) stays forever indistinguishable from live
guidance. A future agent reading backlog executes dead orders. `inReplyTo` links
corrections but nothing marks the *target* as dead.

## Proposed mechanism

`send_message(supersedes: '<message-id>')` — the new message carries a pointer to the
message it replaces. Readers annotate the old entry `{stale: true, by: <new-id>}` at
*read* time. Nothing is ever deleted or rewritten; the log stays append-only.

## Authority rules (the part that needs agreement)

The proposed constraints, adopted as the baseline:

1. **An author may supersede their own message.** Uncontested — self-correction.
2. **The human may supersede anything.** The human's directives are the highest-
   authority content in the log; the human is also the only party who can kill them.
3. **An agent may NOT supersede another agent's message.** Instead it may *nominate*:
   `send_message(supersedes: X)` from a non-author non-human stores
   `{staleNominated: true, by: <msg-id>, byAgent: <sender>}` on the target — visible as a
   dispute, not a kill. The nomination resolves when the author or the human posts a real
   supersede, or posts a rejection (`affirms: X`? — see open questions).

   Why: a supersede-anything rule is a retraction-vandalism vector in a trust log. One
   confused (or prompt-injected) agent could mark the human's standing directive stale and the
   whole fleet would skip it. Nominate-not-kill keeps the disagreement visible without
   giving it force.

4. **DMs cannot be superseded.** A DM already delivered is already read or unread in one
   inbox; marking it stale after the fact changes nothing the recipient relied on, and
   the target file is the recipient's inbox — letting the sender annotate someone else's
   inbox is a cross-writer. Room messages only.

## Propagation points — where the annotation must appear

The failure mode that motivated this: stale directives do their damage on the *delivery*
path, not the archive-read path. So annotation is required at:

- `read_messages(source: room)` — annotate in the returned entries.
- `wait_for_message` backlog deliveries — the interrupt path. A seat woken by a
  superseded directive must see `{stale}` on it in the same payload, not on a later
  re-read.
- `retrieve_room_history` digests — same.
- The tmux/herdr pushers: out of scope for v1 (they type what they're given; the store
  annotation can't reach a line already typed). Acceptable — pusher delivery is
  near-real-time, so the supersede usually lands before a slow reader acts. Document the
  gap.

## Ordering and races

- **Supersede of a supersede**: allowed (author may supersede their own correction).
  Readers render the *latest* annotation, i.e. walk the chain to the live tip.
- **Supersede arriving before the target in a reader's window** (compaction moved the
  target to archive): the supersede still stores fine; readers that can't resolve the
  target render it as `supersedes <id> (target archived/not in window)`. Fail visible,
  not silent.
- **Two agents superseding the same target**: only the author or the human's supersede counts;
  the other is automatically a nomination. No lock needed — resolution is by authority,
  not timing.
- **Malformed/unknown target**: malformed id → refuse (mirror inReplyTo's refusal shape,
  messaging.js:318-328). Unknown id → store + warn, same as inReplyTo (the target may be
  in an archive the existence check missed — `messageIdExists` at :197 already scans
  archives, so this is cheap to reuse).

## Edge cases to decide before building

- **Does `kind: 'decision'` change anything?** Decisions are kept ~30 days and quoted in
  digests. A superseded decision should probably still quote in digests but flagged
  `[SUPERSEDED]` — digests are exactly where stale authority does damage.
- **`affirms` (reversal of a nomination)**: is an explicit "no, still live" needed, or is
  the absence of a real supersede enough? Leaning: not needed in v1 — the nomination is
  already visibly only a nomination.
- **Self-supersede chains in compaction**: if the superseding message is archived and
  the target survives as a fresh decision, the target loses its `stale` marker.
  Mitigation: when compacting, carry forward a `supersededBy` hint onto kept entries, or
  exempt superseded decisions from the freshness exemption (a dead decision doesn't need
  keeping).

## Failure-mode checklist (adversarial pass)

- Retraction vandalism → blocked by rule 3 (nominate-not-kill).
- Stale-directive replay on the wake path → covered by annotating wait_for_message.
- Silent authority grab (agent superseding the human) → refused at send, fail closed.
- Confused future agent reading a stale flag as "deleted" → render as `stale (see <id>)`,
  pointer always included.
- Supersede spam (agent marking everything nominated) → nominations are cheap and
  visible; if it happens the room sees it in-band. No rate limit in v1, note it.

## What this deliberately does not do

- No deletion, no rewriting history, no editing other agents' inboxes.
- No new room state — supersede is just a field on an ordinary message plus read-time
  rendering. The store format is unchanged.
- No pusher/transport changes in v1.
