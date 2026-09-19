<!-- agent-coord:begin -->

## Team coordination

This workspace runs a coordinated agent team. Read **COORDINATION.md** (how the
room works: bus, rooms, recess) and **ORGANICS.md** (team personality — how to
act like a person here, not a process). Both are workspace copies; edit
ORGANICS.md to tune this team's default behavior.

- The bus is `.devin/agent-coord/state/` via the `agent-coord` MCP server —
  one entry for every tab. `join` with your name; your name IS your identity
  and never changes.
- The roster is in `.devin/coord.json`; your profile and memory live in the
  machine's identity registry at `~/.local/state/agent-coord/agents/<you>/` —
  read it at session start, add to it before you stop.
- The team chat UI: `coord chat start {{PROJECT}}` then open the printed URL.

<!-- agent-coord:end -->
