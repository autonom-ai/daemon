# Autonom Research Notes

These files record the codebase and repository-style research requested for
the `interactive-acp` branch. They describe evidence at revision
`08a8af4bb4321021c3f4ef4f167ea14d55c23dc1` (2026-10-16); they are not
implementation documentation or a refactor plan.

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
- [Reference style study](reference-style.md) — observed code examples from
  this repository, `intuit`, `selenium`, Insurgent Client, and Devin Better
  ACP.
- [Style-rules revision](style-rules-revision.md) — replacement draft for the
  user's global conventions, with D access/attribute edge cases and evidence
  from `intuit`, `selenium`, Webull SDK, Akashi, Insurgent API/client, and Apps.
- [Verification snapshot](verification.md) — commands/results at the audited
  revision and the limits of what they establish.

The evidence is tied to the revision above. File line numbers can change with
later commits. No implementation files were edited for this research. The
`.gitignore` has a narrow allowlist so these requested documents can be
reviewed without unignoring the rest of `research/`.
