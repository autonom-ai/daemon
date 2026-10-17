# Development

- D: `dub build --compiler=ldc2 --config=daemon` and
  `dub build --compiler=ldc2 --config=relay`.
- Tests: `dub run --compiler=ldc2 --config=unit --build=unittest`.
  These launch the production daemon on loopback port 18080; run serially.
- Launcher: Node 22+, `npm --prefix source/launcher ci`, then
  `npm --prefix source/launcher run check` and
  `npm --prefix source/launcher test`. Output is repository-root `dist/`.
- Real CLI integration: `dub run --compiler=ldc2 --config=unit --build=unittest
  --d-version=devin`; isolates XDG state and requires no model credentials.
- Installed Desktop build check: `npm --prefix source/launcher run test:integration`.
  This reads the actual installation; it does not launch Desktop or validate UI.
- MCP: `python3 source/mcp/tests.py` (standard library only).
- Installer: `python3 install.py`; build as the normal user. For a protected
  installation, build first, then `sudo python3 install.py --no-build`.
  Installer tests use temporary installation trees, never profile copies.
- There is no eval configuration. Use `--skip-registry=all` with DUB when
  dependencies are already cached and network access is unavailable.

# Ownership

- `daemon.app` / `daemon.server`: entrypoint and one persistent Serverino
  worker. `daemon.runtime` assembles the worker-owned domain objects.
- `daemon.interop`: CLI processes, canonical sessions, ACP, and capabilities.
  The read-only CLI database supplies session metadata and conversation history.
- `daemon.agent`: profiles and durable assignments. `daemon.coord`: rooms,
  streams, and cursors. `daemon.events`: pending events, schedules, and wakes.
- `daemon.policy` / `daemon.hooks`: policy screening and authenticated hooks.
- `source/mcp/server.py`: stdio JSON-RPC proxy to the daemon.
- `source/launcher`: Desktop startup, native runtime, page bridge, and settings.
  `assets`: configured pages. `install.py`: transactional installation.

See [daemon architecture and cutover](docs/DAEMON.md) for current lifecycle,
HTTP, permission, and deployment contracts.

# Invariants

- Keep mutable registries and domain state on the single worker. Monitor
  threads own only their child and live call state. The scheduler thread
  pokes loopback refresh; it does not mutate stores.
- Own session IDs and retained request strings; Serverino buffers are reused.
- Keep child work and human waits outside the HTTP worker. Bound processes,
  output, requests, and deadlines; cancel and reap owned children safely.
- Discovery does not grant control. Scope capabilities to their session/run;
  never expose operator credentials to pages, children, or logs. Scrub inherited
  host ACP/Desktop variables. Keep credential-bearing configuration private.
- Open the CLI database read-only. A held foreign lock means loaded elsewhere,
  not active generation or permission to control that process.
- Preserve configuration, data, sessions, and file logs. Reconcile uncertain
  interrupted wakes without blindly replaying prompts.
- Enforce policy on `PreToolUse`, including automatic/bypassed calls.
  Human permission requests use native Desktop and HTTP, without a custom UI.

# Style and refactor

Use [the adopted style revision](research/style-rules-revision.md) and
[the simplification plan](research/plan.md). Prefer direct domain ownership,
small intentional APIs, and language-native code. D and TypeScript use
four-space Allman layout, meaningful camelCase names, PascalCase types, and
`ret` for constructed results. Group project, dependency, then runtime imports.
Use intentional access sections and field-like accessors; choose `auto`, `ref`,
`@property`, and lifetime attributes for their semantics. Python follows Python
conventions. Tests follow Selenium's domain layout and `@Name`/`unittest`,
`@ShouldFailWith`, and scope cleanup conventions. Prefer real components;
model simulation and narrow installer filesystem fixtures are permitted.
Keep tests against installed peers in explicit integration suites. Avoid unrelated formatting and speculative abstractions.

# Desktop safety

Read [the Desktop contract](docs/COMMAND_CENTER.md) and
[the validation procedure](docs/COMMAND_CENTER_VALIDATION.md) before changes
to native integration. Respect the pinned build and integrity checks. Only
patch the installed CLI shim and copy the launcher payload; never rewrite
vendor bundles, checksums, CSP, or profile data, weaken sandboxing, or hide
integrity warnings. Runtime patches must restore exact descriptors.

Live tests use a separate window, never the communication window. Tests may
observe and operate real controls; they may not synthesize the product surface
they claim to validate. Unit tests do not close live acceptance gates. Record
raw output and screenshots, and report unverified gates explicitly.
