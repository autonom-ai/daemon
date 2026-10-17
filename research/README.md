# Autonom Research Notes

The evidence files below describe the codebase at revision
`08a8af4bb4321021c3f4ef4f167ea14d55c23dc1` on `interactive-acp` (2026-10-16).
The plan and dispositions follow that research and the user's subsequent
clarifications; they describe the proposal at that baseline. Current behavior
and remaining source/deployment gates are documented in [daemon architecture](../docs/DAEMON.md)
and tracked under Linear ANM-36.

- [Simplification plan](plan.md) — clarified requirements, architectural
  decisions, integration gates, sequencing, and acceptance criteria.
- [File and folder dispositions](disposition.md) — keep, simplify, fold,
  replace, and remove recommendations for the complete baseline inventory.

- [Architecture review](review.md) — ownership boundaries, integration
  observations, the user-provided design lens, and questions the source does
  not resolve.
- [Daemon inventory](daemon-map.md) — every tracked file and directory under
  `source/daemon/`.
- [Remaining repository inventory](repo-map.md) — other tracked source,
  launcher, UI, tests, build, install, and documentation files.
- [Session and ACP investigation](sessions-acp.md) — the CLI database, bridge
  sessions, execution lifecycle, managed ACP, and relay-observed ACP paths.
- [Permission investigation](permissions.md) — the HTTP hook-to-human approval
  exchange and the state it holds.
- [Autonom code style](style-rules-revision.md) — corrected D conventions
  derived from the current `intuit`, `selenium`, `akashi`, and `multidasm`
  source trees, plus the project's TypeScript and Python guidance.
- [Verification snapshot](verification.md) — commands/results at the audited
  revision and the limits of what they establish.

The evidence is tied to the revision above. File line numbers can change with
later commits. No implementation files were edited for this research. The
`.gitignore` has a narrow allowlist so these requested documents can be
reviewed without unignoring the rest of `research/`.
