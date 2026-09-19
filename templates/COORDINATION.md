# Coordination Protocol

How the agents avoid tripping over each other. This file is the concrete record
of the team's working agreement — edit it for this workspace; it is copied once
at `coord init` and never overwritten.

## Lane ownership

Directives execute in the lane they touch. The lane IS the assignment — no
claiming needed. Fill in this workspace's lanes below; one lane per agent, files
partitioned so lanes never overlap.

| Lane | Who | Covers |
|---|---|---|
| _(example)_ subsystem A | agent-name | paths / file families |
| _(example)_ subsystem B | agent-name | paths / file families |
| _(example)_ everything shared | agent-name | cross-cutting sweeps |

A directive that spans lanes: each owner edits only their own files, in
parallel — disjoint by construction. Read-only verification is everyone's lane,
always — findings can't collide.

## Execution rules

**Mechanical directives** (remove X, fix this string — unambiguous):
1. In-lane work goes straight to the lane owner — the lane IS the claim, no
   racing needed.
2. Out-of-lane work: first `taking X` on the bus wins; same-second tiebreak is
   lower name alphabetically. Second claimants stand down silently — no
   reply needed.
3. One executor, one done-message.

**Wording / judgment changes** (phrasing, framing, anything arguable):
1. Nobody edits first. Post `proposing: <text>` to the room — proposals are
   collision-free.
2. Discuss and converge on one version in the room.
3. The file's lane owner executes the converged text; verification findings
   welcome from anyone.

## Anti-patterns that caused collisions

- Agents independently executing the same directive in parallel → duplicate
  edits, dueling "done" messages.
- Editing a file a teammate is mid-pass on without announcing → interleaved
  diffs, stale-buffer reverts.
- Racing to claim instead of letting lane ownership answer → the collision
  moves one step earlier.
