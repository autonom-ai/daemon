# Non-daemon repository map

## Snapshot and inventory boundary

This map describes tracked paths at repository `HEAD` **08a8af4**
(`08a8af4bb4321021c3f4ef4f167ea14d55c23dc1`). The exhaustive file manifest was
`git ls-files`, checked against `HEAD`; it contains 118 files. Of those, 70 are
outside `source/daemon/` and are inventoried below. The other 48 tracked files
under `source/daemon/` are outside this non-daemon inventory. Directory names
below are derived from those tracked file paths (Git tracks files, not empty
directories): 14 directory paths contain the inventoried files.

`research/repo-map.md` is the audit output, not a file in the HEAD manifest.
The committed `.gitignore` ends in `research/*` (line 24), so this path is
ignored at the specified HEAD. The working tree also had a local modification
to `.gitignore` during inspection; the `.gitignore` entry below describes its
committed HEAD contents, not that local delta.

## Directory map

| Directory path | Responsibility / relationships |
| --- | --- |
| `.github/` | GitHub automation configuration. |
| `.github/workflows/` | CI workflow; it runs the DUB daemon build, D unit tests, and eval-runner build, not the launcher npm or Python MCP test commands (`ci.yml:8-23`). |
| `assets/` | Command Center definition and presentation resources consumed by `source/launcher/config.ts` and `runtime.ts`; the launcher doc describes this resource set (`docs/COMMAND_CENTER.md:72-115`). |
| `assets/actions/` | Renderer-side JavaScript action files referenced by a Command Center definition. |
| `assets/icons/` | SVG marks imported into the injected runtime. |
| `assets/pages/` | HTML page actions loaded on selection. |
| `docs/` | Tracked Command Center integration contract and validation procedure. |
| `source/` | Mixed source root: the daemon subtree is excluded here; the launcher, MCP adapter, and D test/support subtree are included. |
| `source/launcher/` | Node/TypeScript launcher, browser runtime, build configuration, and unit tests. `package.json` builds bundles into repository-root `dist/`. |
| `source/launcher/tests/` | Launcher test support and tests. |
| `source/launcher/tests/unit/` | Node `node:test` module and installer tests; it is the only tracked launcher test subtree. |
| `source/mcp/` | Standard-library Python stdio MCP server and Python contract tests. The server proxies to daemon HTTP endpoints. |
| `source/tests/` | D unit tests, their shared fixture/helper, and a fake agent used for backend/ACP process contracts. `dub.json` includes this directory in the `unit` configuration. |
| `templates/` | Starting daemon/workspace configuration and hook/MCP installation templates. |

No tracked `source/launcher/tests/integration/` directory or integration
script is present in the manifest. `docs/COMMAND_CENTER.md:166-172` describes
`source/launcher/tests/integration/desktop.mjs` as a live-validation command;
that referenced path is not tracked at this HEAD.

## Build, package, and test relationships

- `dub.json` defines `daemon`, `unit`, and `relay` configurations. The unit
  configuration builds the daemon and relay and generates the unit-test
  entrypoint from `source/tests/` (`dub.json:1-70`). `dub.selections.json`
  pins the DUB dependency versions.
- `.github/workflows/ci.yml` runs `dub build --config=daemon`,
  `dub run --config=unit --build=unittest`, and `dub build --config=eval`.
  The tracked workflow does not invoke `source/mcp/tests.py` or launcher npm
  tests.
- `source/launcher/package.json` requires Node 22+, runs TypeScript checking,
  builds through `build.mjs`, and defines `npm test` as bundle plus Node unit
  tests (`package.json:7-13`). `build.mjs` emits launcher, browser runtime,
  build-verification CLI, and test bundles under repository-root `dist/`.
- `install.sh` builds the daemon and relay plus launcher assets for a normal
  user, then its embedded Python installer installs the launcher payload and
  CLI wrapper. It copies launcher bundles, `cdp.mjs`, daemon hook, MCP server,
  daemon/relay binaries, `assets/`, and `templates/` (`install.sh:1-20,
  340-379`).
- Test evidence is mixed by suite. D tests exercise production D code and,
  where applicable, start the production daemon over loopback port 18080
  (`AGENTS.md:3-6`; `source/tests/common.d:23-78`;
  `source/tests/daemon.d:168-180`); their external Devin/ACP agent is generally
  substituted by `source/tests/fakeagent.py`. MCP Python tests run the real
  Python modules against a local mock HTTP server and patched hook calls, not
  an installed daemon (`source/mcp/tests.py:18-65`). Launcher Node unit tests
  mainly use temporary files, fake CDP transports, synthetic native services,
  and temporary sockets (`source/launcher/tests/support.ts:10-93` and the
  unit-test files below). The installer tests copy selected installed Desktop
  files into a temporary installation tree and supply a fake RPM database
  (`source/launcher/tests/unit/install.ts:13-72`); they exercise installer
  behavior against that temporary tree, not a live user profile. One optional
  launcher test, skipped if the standard path does not exist, verifies the
  installed Desktop build identity at `/usr/share/devin-desktop/resources/app`
  (`source/launcher/tests/unit/desktop.ts:23,163-167`). None of these facts
  make the launcher unit suite a live Desktop UI acceptance run.

## Tracked file inventory

### `.github/`

| Tracked file | Responsibility / evidence |
| --- | --- |
| `.github/workflows/ci.yml` | GitHub Actions workflow for pushes to `main` and pull requests; sets up LDC and builds the daemon, runs D unit tests, and builds the eval runner (`:1-23`). |

### Root files

| Tracked file | Responsibility / evidence |
| --- | --- |
| `.gitignore` | Ignores DUB/binary output, private workspace data, launcher dependencies/build output, and all `research/*` paths at HEAD; it selectively allows the tracked Command Center docs (`:1-24`). |
| `AGENTS.md` | Repository verification/runtime notes and the operational contract for daemon, hooks, profiles, coordination, events, policy, and launcher (`:1-104`). Its launcher section names the source-to-build relationship and its test/build commands (`:88-104`). |
| `LICENSE.txt` | Full GNU Affero General Public License v3 text (660 lines); `dub.json` and launcher package metadata identify the project license as `AGPL-3.0-only`. |
| `dub.json` | DUB package and configurations: daemon executable (`:1-16`); unit test executable, dependencies, generated test entrypoint and pre-build commands (`:17-39`); relay executable (`:40-53`); shared D dependencies, import paths, target output, and package metadata (`:54-70`). |
| `dub.selections.json` | DUB lock/selection file pinning `arsd-official`, `intuit`, `mir-*`, `serverino`, `silly`, `tinyendian`, and `unit-threaded` versions (`:1-15`). |
| `install.sh` | Bash build/check/install wrapper plus embedded Python installer. Supports app selection, no-build, check, and uninstall options; validates and stages the Desktop CLI wrapper and payload and rolls back failed writes (`:1-22,33-49,340-396`). It preserves the original CLI and leaves Desktop application bundles outside the payload/write target (`:356-379`; also `docs/COMMAND_CENTER.md:3-26`). |

### `assets/`

| Tracked file | Responsibility / evidence |
| --- | --- |
| `assets/ATTRIBUTION.md` | Third-party notice for the Autonom icon: Streamline source and CC BY 4.0 terms (`:1-6`). |
| `assets/actions/reload.js` | Renderer action body calling `context.refresh()`; used as the JavaScript reload-action example (`:1`; `docs/COMMAND_CENTER.md:101-111`). |
| `assets/icons/autonom-fill.svg` | Filled Autonom mark; runtime import for the Autonom mode switch (`:1-8`; `source/launcher/runtime.ts:1-3,59-63`). |
| `assets/icons/autonom.svg` | Line Autonom mark paired with the filled mark for mode-switch state (`:1-8`; `source/launcher/runtime.ts:1-3,59-63`). |
| `assets/icons/cloud-fill.svg` | Filled cloud mark used by the Devin Cloud mode switch (`:1`; `source/launcher/runtime.ts:3-4,59-63`). |
| `assets/icons/cloud.svg` | Line cloud mark used by the Devin Cloud mode switch (`:1`; `source/launcher/runtime.ts:3-4,59-63`). |
| `assets/icons/pencil-fill.svg` | Filled pencil/Editor mark used by the Editor mode switch (`:1`; `source/launcher/runtime.ts:5-6,59-63`). |
| `assets/icons/pencil.svg` | Line pencil/Editor mark used by the Editor mode switch (`:1`; `source/launcher/runtime.ts:5-6,59-63`). |
| `assets/pages/events.html` | Static Events page layout for inbox/event stream state. The current page contains example zero-count/empty state; “Poll Now” posts a `getState` message, while its acknowledge control is an alert rather than a daemon mutation (`:223-313`). |
| `assets/pages/policy.html` | Workspace Policy presentation with sample rule cards and local rule filters; “Open Policy File” posts the bridge `editPolicy` action. “Verify Rules” is presentation-only alert behavior (`:220-322`; bridge mapping in `docs/COMMAND_CENTER.md:117-121`). |
| `assets/pages/schedules.html` | Static Schedules presentation with example empty state and schedule types; refresh requests state, while “New Schedule” currently displays guidance rather than submitting a schedule (`:224-314`). |
| `assets/pages/settings.html` | Settings page for launcher port and daemon settings, with launcher/daemon/path sections. It requests settings on load and posts save/open actions over the renderer bridge (`:262-509`; bridge mapping in `docs/COMMAND_CENTER.md:117-131`). |
| `assets/ui.css` | Scoped CSS for the injected mode switch, section heading, busy items, and full-size custom page surface (`:1-64`). |
| `assets/ui.yml` | Default Command Center definition: enabled, active `schedules`, imports native `wiki` for Devin Cloud, declares Schedules/Events/Policy/Settings HTML items, and empty Rooms/Profiles sections (`:1-34`). Launcher default config points here (`source/launcher/launcher.ts:49-53`). |

### `docs/`

| Tracked file | Responsibility / evidence |
| --- | --- |
| `docs/COMMAND_CENTER.md` | Command Center adapter and safety/integration contract: pinned Desktop boundary, install procedure, native UI boundary, assets, bridge actions/settings, private control socket, and launcher build/test commands (`:1-176`). It also specifies content validation limits and page/action loading behavior (`:72-121`). |
| `docs/COMMAND_CENTER_VALIDATION.md` | Validation methodology distinguishing typecheck, unit, live launcher, and adversarial evidence; gives pinned Desktop preconditions, launch/observation procedure, toggle/reload/integrity checks, and result-record fields (`:1-151`). The document describes the above-noted integration script at line 79, but that path is absent from the tracked manifest. |

### `templates/`

| Tracked file | Responsibility / evidence |
| --- | --- |
| `templates/config.yml` | Daemon configuration starting point: data directory, Devin command, execution timeout, compaction/offline wake settings, and OpenRouter fields (`:1-14`; `AGENTS.md:22-25`). |
| `templates/hooks.v1.json` | Eight Devin hook event command mappings to the daemon’s `interop/devin/hook.py`; commands apply the configured shell memory limit and event-specific timeout (`:1-10`; `AGENTS.md:31-33`). |
| `templates/mcp_config.json` | Empty `mcpServers` object; MCP endpoint is injected dynamically rather than configured as a static server entry (`:1-3`; `AGENTS.md:33-34`). |
| `templates/policy.yml` | Starter workspace policy with a screen rule using `inception/mercury-decide:free`, a predicate question, and denial reason (`:1-10`; `AGENTS.md:67-73`). |

### `source/launcher/`

The launcher owns the Devin Desktop process and its private CDP pipe, attaches
the browser runtime, loads the Command Center assets, and connects the renderer
bridge to daemon HTTP. `docs/COMMAND_CENTER.md:3-7,117-146` documents those
boundaries; `AGENTS.md:88-104` describes the file-level division.

| Tracked file | Responsibility / evidence |
| --- | --- |
| `source/launcher/assets.d.ts` | TypeScript module declarations for imported `.svg` and `.css` text assets (`:1-11`). |
| `source/launcher/bridge.ts` | Token-authenticated loopback HTTP bridge for page actions, daemon/client state, launcher and daemon settings, and opening config/policy files (`:11-175`; action dispatch begins at `:95`). |
| `source/launcher/build.mjs` | esbuild orchestration. Produces Node launcher, browser runtime, and build CLI bundles, plus bundles every tracked unit-test TypeScript entrypoint into `dist/tests/unit/` (`:1-52`). |
| `source/launcher/build.ts` | Desktop version/commit/workbench digest pins and build/package integrity verification, including RPM package ownership and file digests (`:8-19,55-210`). |
| `source/launcher/buildcli.ts` | Node entrypoint for the build verifier; calls `build.main()` and reports failure through process exit code (`:1-10`). |
| `source/launcher/cdp.mjs` | Executable CLI for querying the running launcher’s private Unix control socket: status, targets, expression evaluation, screenshot, hot reload, and detach (`:1-92`). |
| `source/launcher/cdp.ts` | CDP request correlation, sessions/events, remote evaluation, and pinned native service/invocation capture (`:1-339`; capture exports at `:224-333`). |
| `source/launcher/center.ts` | Browser-safe content types and transformations: visible/declared items, native overlay manifest, full-document detection, and page wrapping (`:1-122`). |
| `source/launcher/client.ts` | Daemon HTTP client, health/config/capability handling, response bounds, and managed daemon startup when required (`:10-287`; startup at `:216-270`). |
| `source/launcher/config.ts` | Bounded private file reads/writes; YAML UI definition and action loading/path confinement; launcher and daemon setting validation/persistence; default config and router-key access (`:12-527`). |
| `source/launcher/control.ts` | Private Unix control socket implementation: request bounds, live status/targets/eval/screenshot/hot/detach dispatch, and duplicate-launch ownership checks (`:9-210`). |
| `source/launcher/desktop.ts` | Desktop binary resolution, pinned workbench URL, subprocess launch, environment scrubbing, private NUL-framed debugging pipe, and explicit loopback debug transport (`:11-391`). |
| `source/launcher/launcher.ts` | Executable lifecycle: parse arguments, load settings/content, verify Desktop, connect daemon, start bridge and control socket, spawn/attach Desktop, reload assets, and shut down runtime/process resources (`:25-470`). |
| `source/launcher/package-lock.json` | npm lockfile for launcher dependencies and exact transitive versions (`:1-551`). |
| `source/launcher/package.json` | Private Node package; requires Node 22+, defines TypeScript check, bundle, unit-test, and launch commands, and pins YAML/esbuild/TypeScript package versions (`:1-22`). |
| `source/launcher/runtime.ts` | Browser-side overlay/runtime. Imports UI CSS/icons, patches native navigation services in memory, renders mode switch and custom page webview, dispatches bridge actions, tracks status, reloads atomically, and restores descriptors on dispose/lease expiry (`:1-1052`; imports/config at `:1-63`, install at `:267-1052`). |
| `source/launcher/tsconfig.json` | Strict TypeScript compiler configuration; includes launcher and `tests/**/*.ts`, emits to repository-root `dist/` (`:1-22`). |

### `source/launcher/tests/`

`source/launcher/tests/support.ts` supplies a synthetic native manifest,
controller, groups, command API, and content fixture (`:10-110`). These fixtures
are module-contract inputs, not a mounted Desktop UI.

| Tracked file | Responsibility / evidence |
| --- | --- |
| `source/launcher/tests/support.ts` | Shared fake native-service object and representative content/runtime bridge fixture (`:10-110`). |
| `source/launcher/tests/unit/bridge.ts` | Starts the real bridge on a temporary loopback port with a stub daemon client; verifies auth/CORS, state/path responses, UI action request scope, and settings writes (`:13-215`). |
| `source/launcher/tests/unit/build.ts` | Temporary app trees and mocked package lookup test Desktop build identity, package ownership/digests, file-type checks, and fail-closed cases (`:18-256`). |
| `source/launcher/tests/unit/cdp.ts` | Fake `PassThrough` pipe/browser tests for CDP request correlation, session scoping, evaluation, and capture success/failure (`:8-174`). |
| `source/launcher/tests/unit/center.ts` | Tests content schema/order, lazy action reads, native imports, path confinement, and action revision/cache behavior (`:1-218`). |
| `source/launcher/tests/unit/config.ts` | Temporary-file tests for launcher settings YAML, daemon config fields, path resolution, and preserving unrelated settings on writes (`:1-129`). |
| `source/launcher/tests/unit/content.ts` | Tests `runtime` overlay content calculations: native navigation preservation, sections/items, native imports, and fragment/full-document CSP handling (`:1-93`). |
| `source/launcher/tests/unit/control.ts` | Exercises a temporary Unix socket with injected test context for status/targets/eval and socket ownership/refusal behavior (`:1-136`). |
| `source/launcher/tests/unit/desktop.ts` | Temporary pipes/processes/socket endpoints test framing, resolution, pin rejection, debug endpoint/port validation, and environment scrubbing. A separately skippable case checks the installed product’s build pin/package when the conventional install exists (`:1-228`, especially `:163-167`). |
| `source/launcher/tests/unit/install.ts` | Executes `install.sh` against temporary copied installation trees with fake RPM behavior; covers wrapper argv/stdio/exit, install/uninstall, package generations, external edits, symlinks, rollback, and pin refusal (`:13-20,22-97,104-468`). The copied app inputs come from `/usr/share/devin-desktop/resources/app`; mutations are to the temporary fixture, not the live product/profile. |
| `source/launcher/tests/unit/runtime.ts` | Synthetic service fixture tests for overlay immutability/descriptor restore, reload/provider mode, lazy pages/scripts, failed replacements, disposal, and lease behavior (`:1-279`). |

### `source/mcp/`

| Tracked file | Responsibility / evidence |
| --- | --- |
| `source/mcp/server.py` | Standard-library-only Python MCP stdio JSON-RPC server. Advertises coordination tools for managed sessions and proxies them to loopback daemon HTTP; uses a daemon-issued `AUTONOM_MCP_TOKEN`, resolves the owning session through `/api/mcp/session`, and can ensure/start the daemon (`:1-8,11-20,22-203,206-538`). |
| `source/mcp/tests.py` | Python `unittest` contract tests for `server.py` and the daemon hook: unmanaged tool visibility, token/session headers, token-file hook auth, fail-closed hooks, permission approval polling, and argument errors (`:1-181`). Its mock daemon is a local `HTTPServer` and the hook calls are patched (`:18-65`); these tests do not observe an installed daemon product. |

### `source/tests/`

These are D unit-test modules compiled by the DUB `unit` configuration.
`source/tests/common.d` provides temporary configuration/data fixtures and an
HTTP request helper aimed at loopback port 18080; `installFake` points the
configured Devin command at `fakeagent.py` (`common.d:23-78,81-135`). The
tracked suite therefore covers production D components, but uses a synthetic
agent for agent-process/ACP interactions rather than exercising an installed
Devin CLI as its backend.

| Tracked file | Responsibility / evidence |
| --- | --- |
| `source/tests/acp.d` | Tests relay byte forwarding/exit propagation, session-frame rewriting and credential binding, MCP coordination-server injection, ACP client protocol, permissions, and authenticated relay control socket (`:92-514`; imports `injectCoord` at `:3-5`). Uses the fake agent ACP mode (`:22-35`). |
| `source/tests/bridge.d` | Tests `Devin` bridge session handle ownership, CLI session listing, print requests, backend errors/timeouts, and session/log removal (`:18-97`). |
| `source/tests/common.d` | Shared test HTTP helper with control/run/session/MCP headers and 18080 loopback target; temporary config/profile fixture; fake CLI installation and bounded wait helper (`:23-135`). |
| `source/tests/config.d` | Tests configuration-relative paths/defaults, OpenRouter construction, required/unsupported settings, duration/wake values, and symlink rejection (`:12-172`). |
| `source/tests/coord.d` | Tests coordination route declarations, messages/streams/cursors, window trimming/persistence, visibility/admin rules, DMs/pings, and invalid/symlinked storage (`:30-238`). |
| `source/tests/daemon.d` | HTTP-level daemon tests: endpoint declarations, lifecycle/state, coordination and unread-event gate, schedules/wakes, unmanaged/managed capability behavior, human chat, session observation, and MCP admission/binding (`:158-951`; production daemon fixture at `:168-180`). |
| `source/tests/database.d` | Tests session metadata and main-chain history extraction from SQLite fixtures, plus symlink rejection (`:30-101`). |
| `source/tests/events.d` | Tests event/schedule endpoints and persistence, matching/cursors, database fallback, ping/schedule wake and compact behavior, workspace adoption ambiguity, and failure re-surfacing (`:168-526`). |
| `source/tests/fakeagent.py` | Synthetic process backend for test fixtures. Implements fake ACP and CLI modes, session locks/calls/prompts, hook behavior, and controlled outcomes (`:10-328`; invoked by `common.d:113-122` and `acp.d:22-35`). |
| `source/tests/permission.d` | Tests explicit human permission decisions and ownership of copied hook input (`:8-33`). |
| `source/tests/policy.d` | Tests policy route, first-match/local decisions, workspace reload, typed screening and fallback models, unchanged screening input, router context clearing, malformed decisions/documents, and bounded regular-file validation (`:81-407`). |
| `source/tests/profile.d` | Tests profile endpoints, canonical names, one-time legacy import, persistence/failure atomicity, session assignments/rebinding/locks, validation, removal, and private/symlinked storage (`:20-294`). |
| `source/tests/session.d` | Tests session cleanup/ID validity, foreign lock state, create/resume/stop/error lifecycle, host environment stripping, interrupted execution records, and record version compatibility (`:25-314`). |

## Changes since audit baseline `0c4e09e`

`git diff --name-status 0c4e09e..HEAD -- . ':(exclude)source/daemon/**'`
reports these seven tracked non-daemon files as changed: `AGENTS.md`,
`dub.json`, `source/mcp/server.py`, `source/mcp/tests.py`,
`source/tests/acp.d`, `source/tests/common.d`, and `source/tests/daemon.d`.
The source changes that affect this map are recorded as current facts:

- The current MCP server uses daemon-issued session-bound MCP capability
  resolution at `/api/mcp/session`; its exposed tool schemas no longer require
  an injected `session_id` (`source/mcp/server.py:1-8,29-52,205-340`).
- Current Python tests model the capability and hook contract using a local
  mock HTTP server and patched hook calls (`source/mcp/tests.py:18-65,67-177`).
- Current ACP tests cover MCP server injection and relay session credential
  binding (`source/tests/acp.d:199-247`) and add the relay control-socket
  interaction (`:380-514`). The common HTTP helper now carries an MCP token
  header (`source/tests/common.d:23-78`).
- Current daemon HTTP tests include managed/unmanaged MCP capability and
  observed-session admission cases (`source/tests/daemon.d:699-951`).
- Current `dub.json` unit configuration excludes only
  `source/daemon/relay/package.d` from test sources and invokes the relay
  configuration as a pre-build step (`dub.json:21-39`).
- `AGENTS.md` is the current repository verification and architecture guidance
  listed above; it is tracked documentation, not an executable implementation.
