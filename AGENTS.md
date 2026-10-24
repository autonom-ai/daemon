# Autonom Daemon — Agent Guide

## Build & Verification

- Build command: `dub build --compiler=ldc2 --config=daemon` (produces `bin/autonom`).
- Offline D unit suite: `dub run --compiler=ldc2 --config=unit --build=unittest` (binds loopback port `18080`; run serially).
- Real CLI integration: `dub run --compiler=ldc2 --config=unit --build=unittest --d-version=devin` (isolates XDG state; requires no model credentials).
- Python suites: `python3 source/mcp/tests.py`, `python3 tests/command.py`, `python3 tests/install.py`.
- Style & boundary check: `python3 /home/cet/Repos/Autonom/.devin/skills/style/tools/check-style.py`.
- Add `--skip-registry=all` to DUB commands when dependencies are cached and network access is unavailable.
- Write temporary files, test captures, or restoration backups to `/home/cet/Repos/Autonom/.scratch/`, never into the repository tree.

## Boundaries

- `app` (`source/app.d`) only dispatches `daemon`, `acp`, `mcp`, and `hook`. `daemon.api` assembles the single-worker domain stores (`profileStore`, `roomStore`, `bus`, `scheduler`, `bridge`, `policy`).
- `daemon.interop` must never import `daemon.coord`, `daemon.events`, `daemon.policy`, or `daemon.acp`.
- `daemon.policy` & `daemon.hooks` own `.devin/policy.yml` screening via Intuit and authenticated Devin CLI lifecycle hooks.
- Module responsibilities: see the Modules table in `README.md`.

## Invariants

- Keep mutable registries and domain state on the single Serverino worker. Monitor threads own only their child and live call state; the scheduler thread pokes loopback refresh without mutating stores directly.
- Own session IDs and retained request strings; Serverino request buffers are reused across requests.
- Keep child process waits and human permission waits outside the HTTP worker. Bound processes, output, requests, and deadlines; cancel and reap owned children safely.
- Discovery does not grant control. Scope capabilities to their session and run; never expose operator credentials to pages, child processes, or logs. Remove inherited `ACP_BACKEND` when invoking Devin CLI.
- Open the Devin CLI SQLite database read-only (`SQLITE_OPEN_READONLY`).
- Enforce workspace policy on `PreToolUse`, including automatic and bypassed calls, and fail closed when authentication or policy parsing fails.

## Style & Documentation

Follow [CONTRIBUTING.md](CONTRIBUTING.md) and the workspace `style` skill.
