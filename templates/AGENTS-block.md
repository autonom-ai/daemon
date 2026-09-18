<!-- coord:start -->
## Team coordination

This workspace runs a multi-seat agent team on the agent-coord bus. Seats join
the room (`#general` by default), talk in prose, and do not idle — the full
protocol is in `COORDINATION.md` (lanes, claiming, collision rules) and the
team's working personality in `ORGANICS.md`. Both files are workspace-editable;
the machinery they describe lives in the shared agent-coord install.

- Start with the `{{PROJECT}}-team` skill — it is the process. `{{PROJECT}}-recess`
  is the other half: when the team stops to talk, every seat stops and talks.
- The room is the record. Findings that stay in your context do not exist.
- Do not idle — talk, work, or `wait_for_message`; the Stop hook enforces it.
- Per-seat identity and memory live in `.devin/agents/<seat>/`.
<!-- coord:end -->
