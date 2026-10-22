# Autonom Daemon — Agent Guide

## Code Intelligence: CodeGraph & Graphify Pro

This repository uses **CodeGraph** and **Graphify Pro** together. They are complementary and must be used according to what each indexes:

1. **CodeGraph (`codegraph_explore` MCP tool or `codegraph explore "<query>"` CLI) — Primary for D and local AST structure**:
   - **CodeGraph supports D (`ldc2` + `dcd-server` via `codegraph.json`); Graphify's AST extractor does not parse D.**
   - Always call `codegraph_explore` before `grep` or `read` when locating symbols, tracing call paths, inspecting `daemon.*` modules, or checking the blast radius and test coverage of a change in `source/`.
2. **Graphify Pro (`graphify` MCP server) — Primary for Memory, Formal Verification, Reviews, Learn, and Cross-Repo Semantics**:
   - **Memory (`remember`, `recall`, `memories_about`)**: Retrieve durable workspace notes before architectural changes and record newly established contracts or post-mortems with `remember` (`repository_id: "autonom-ai/daemon"`).
   - **Cross-repo & Python context (`query_graph`, `impact_and_risk`, `graphify_trace`)**: Query the `autonom-ai/daemon` repository or the `daemon + intuit` workspace (`c88bab7a-da6a-4ed6-af33-8f8f31dd373d`) for Python MCP/installer flows and Intuit router integration.
   - **Formal Verification, Reviews & Learn**: Use Graphify Pro's verification, review, and learn capabilities to audit protocol invariants, state transitions, and diffs.

## Build & Verification

- Build command: `dub build --compiler=ldc2 --config=daemon` (produces `bin/autonom`).
- Offline D unit suite: `dub run --compiler=ldc2 --config=unit --build=unittest` (binds loopback port `18080`; run serially).
- Real CLI integration: `dub run --compiler=ldc2 --config=unit --build=unittest --d-version=devin` (isolates XDG state; requires no model credentials).
- Python suites: `python3 source/mcp/tests.py`, `python3 tests/command.py`, `python3 tests/install.py`.
- Style & boundary check: `python3 /home/cet/Repos/Autonom/.devin/skills/d-style/tools/check-style.py`.
- Add `--skip-registry=all` to DUB commands when dependencies are cached and network access is unavailable.
- Write any temporary files, test captures, or restoration backups to `/home/cet/Repos/Autonom/.scratch/`, never into the repository tree.

## Ownership & Layer Boundaries

- `app` (`source/app.d`): Single command dispatching `daemon`, `acp`, `mcp`, and `hook`.
- `daemon.api`: Assembles the single-worker domain stores (`profileStore`, `roomStore`, `bus`, `scheduler`, `bridge`, `policy`).
- `daemon.interop`: Devin CLI processes, canonical sessions, ACP client/routing, read-only CLI SQLite inspection (`daemon.interop.devin.db`), and capabilities. Must never import `daemon.coord`, `daemon.events`, `daemon.policy`, or `daemon.acp`.
- `daemon.agent`: Profiles and durable session assignments.
- `daemon.coord`: Rooms, streams, and per-profile cursors.
- `daemon.events`: Pending events, schedules, and wakes.
- `daemon.policy` & `daemon.hooks`: `.devin/policy.yml` screening via Intuit and authenticated Devin CLI lifecycle hooks.
- `source/mcp/`: Stdio JSON-RPC MCP proxy (`autonom-coord`) and `daemon --ensure` helper.
- `templates/` & `install.py`: Packaged configuration/hook templates and user-level installer.

## Invariants

- Keep mutable registries and domain state on the single Serverino worker. Monitor threads own only their child and live call state; the scheduler thread pokes loopback refresh without mutating stores directly.
- Own session IDs and retained request strings; Serverino request buffers are reused across requests.
- Keep child process waits and human permission waits outside the HTTP worker. Bound processes, output, requests, and deadlines; cancel and reap owned children safely.
- Discovery does not grant control. Scope capabilities to their session and run; never expose operator credentials to pages, child processes, or logs. Remove inherited `ACP_BACKEND` when invoking Devin CLI.
- Open the Devin CLI SQLite database read-only (`SQLITE_OPEN_READONLY`).
- Enforce workspace policy on `PreToolUse`, including automatic and bypassed calls, and fail closed when authentication or policy parsing fails.

## Style & Documentation

Follow [CONTRIBUTING.md](CONTRIBUTING.md) and the workspace `d-style` skill. Use four-space Allman layout, `PascalCase` types and enum members, `camelCase` values and constants, explicit local types, and `ret` for constructed return values. Document public declarations with `///` Ddoc comments and Python functions with docstrings for automated GitHub Pages generation. Keep files under 400 lines (aiming for ~200 lines).

## Cross-Repository Contract

The Desktop launcher lives in [autonom-ai/devin](https://github.com/autonom-ai/devin). It discovers `autonom` on `PATH` and never bundles the daemon or its configuration templates.
