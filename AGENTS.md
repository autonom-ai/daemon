# Development

<!-- graphify-rules-start (managed by `graphify init`) -->
## Use Graphify before grep

This repository is indexed by Graphify: a code graph over its call, dependency, and test structure, exposed through a connected Graphify MCP server. Before reaching for grep or reading files, use the Graphify tools your MCP client lists (their exact names and descriptions are in the server's tool list) for what the graph knows and a text search does not:

- find where a symbol, function, or class is defined (instead of grepping for it)
- understand how something works, or where a behavior is handled
- find who calls a function, or what it calls
- see what a change affects (its blast radius) and which tests cover it
- map a file's dependencies and dependents

Fall back to grep or file reads only for what the graph does not model: literal string or comment matches, non-indexed files, or reading a file you have already located. If no Graphify tools are listed, check the MCP server connection.
<!-- graphify-rules-end -->

- D: `dub build --compiler=ldc2 --config=daemon` produces `bin/autonom`.
- Tests: `dub run --compiler=ldc2 --config=unit --build=unittest`.
  These launch the production daemon on loopback port 18080; run serially.
- Real CLI integration: `dub run --compiler=ldc2 --config=unit --build=unittest
  --d-version=devin`; isolates XDG state and requires no model credentials.
- MCP: `python3 source/mcp/tests.py` (standard library only).
- Command surface: `python3 tests/command.py` (standard library only).
- Installer: `python3 install.py`; user level, no `sudo`. Use `--prefix` for a
  temporary tree and `--check` or `--uninstall` for the installed state.
  Installer tests use only temporary prefixes, never profile copies.
- There is no eval configuration. Use `--skip-registry=all` with DUB when
  dependencies are already cached and network access is unavailable.

# Ownership

- `app`: the single command that dispatches the daemon, the ACP host, the MCP
  proxy, and the hook.
- `daemon.api` assembles the worker-owned domain objects.
- `daemon.interop`: CLI processes, canonical sessions, ACP, and capabilities.
  The read-only CLI database supplies session metadata and conversation history.
- `daemon.agent`: profiles and durable assignments. `daemon.coord`: rooms,
  streams, and cursors. `daemon.events`: pending events, schedules, and wakes.
- `daemon.policy` / `daemon.hooks`: policy screening and authenticated hooks.
- `source/mcp/server.py`: stdio JSON-RPC proxy to the daemon.
- `templates`: the configuration, policy, and hook assets the daemon installs.
- `install.py`: the user-level installation of the command and its runtime.

See [daemon architecture and cutover](docs/ARCHITECTURE.md) for current
lifecycle, HTTP, permission, and deployment contracts.

# Invariants

- Keep mutable registries and domain state on the single worker. Monitor
  threads own only their child and live call state. The scheduler thread
  pokes loopback refresh; it does not mutate stores.
- Own session IDs and retained request strings; Serverino buffers are reused.
- Keep child work and human waits outside the HTTP worker. Bound processes,
  output, requests, and deadlines; cancel and reap owned children safely.
- Discovery does not grant control. Scope capabilities to their session/run;
  never expose operator credentials to pages, children, or logs. Remove inherited
  `ACP_BACKEND` when invoking Devin CLI. Keep credential-bearing configuration
  private.
- Open the CLI database read-only. A held foreign lock means loaded elsewhere,
  not active generation or permission to control that process.
- Preserve configuration, data, sessions, and file logs. Reconcile uncertain
  interrupted wakes without blindly replaying prompts.
- Enforce policy on `PreToolUse`, including automatic/bypassed calls.
  Human permission requests use native Desktop and HTTP, without a custom UI.

# Style and refactor

Use [the style guide](docs/DEVELOPMENT.md). Prefer direct domain ownership,
small intentional APIs, and language-native code. D and TypeScript use
four-space Allman layout, meaningful camelCase names, PascalCase types, and
`ret` for constructed results. Group project, dependency, then runtime imports.
Use intentional access sections and field-like accessors; choose `auto`, `ref`,
`@property`, and lifetime attributes for their semantics. Python follows Python
conventions. Tests follow Selenium's domain layout and `@Name`/`unittest`,
`@ShouldFailWith`, and scope cleanup conventions. Prefer real components;
model simulation and narrow installer filesystem fixtures are permitted.
Aim for 200 lines per file; stay under 400, reserving longer files for one
cohesive owner. Keep tests against installed peers in explicit integration suites. Avoid unrelated formatting and speculative abstractions.

# Cross-repository contract

The Desktop launcher lives in [autonom-ai/devin](https://github.com/autonom-ai/devin).
It discovers `autonom` on `PATH` and never bundles the daemon. The command
surface in [docs/CLI.md](docs/CLI.md) is the only interface between them.
