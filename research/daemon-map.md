# Daemon source inventory (HEAD `08a8af4`)

Scope: tracked files under `source/daemon/` at `08a8af4bb4321021c3f4ef4f167ea14d55c23dc1` on
`interactive-acp`. References below are paths and line numbers in that commit. This is a source inventory;
“runtime” means a module used by the running daemon/relay, not a generated artifact.

## Tracked directories and file status

Tracked directories: `source/daemon/`, `agent/`, `coord/`, `events/`, `interop/`, `interop/acp/`,
`interop/devin/`, `policy/`, and `relay/`.

The tracked files are D source modules plus the two Python files under `interop/devin/`; there are no
tracked generated outputs or standalone schema files in this subtree. `package.d` files are D package
modules (mostly public re-exports), not generated files. `source/daemon/app.d` is the daemon executable
entrypoint (`dub.json:4-15`); `source/daemon/relay/package.d` is separately configured as the
`autonom-acp` executable (`dub.json:41-52`). `interop/devin/hook.py` is the CLI hook runtime; `stub.py`
is a path-specific shim, not a schema or generated source. The worktree also has an ignored
`interop/devin/__pycache__/` directory, not present in the tracked tree at this commit
(`.gitignore:7`).

## Composition and cross-cutting flow

- `app.d` passes the endpoint modules to `ServerinoMain!`; that list includes agent profile/store,
  coordination access, client, event/schedule, hooks, policy access, server, Devin bridge, executions,
  MCP, permissions, and sessions (`source/daemon/app.d:3-34`). `runtime.d` separately imports package
  modules and creates the shared `Config`, Devin `bridge`, `ProfileStore`, `EventStore`, coordination
  `Bus`, `ScheduleStore`, `Scheduler`, `Policy`, and `PermissionStore`
  (`source/daemon/runtime.d:3-9,13-35`).
- Serverino startup binds loopback using `AUTONOM_PORT` (default `8080`); worker start calls runtime
  setup, an initial refresh, and starts the scheduler. Worker stop closes runtime state
  (`source/daemon/server.d:59-75,131-134`; `source/daemon/runtime.d:25-43`). The priority-100 request
  refresh calls `scheduler.refresh` (`source/daemon/server.d:111-129`). The scheduler also owns its
  thread and loopback refresh poke (`source/daemon/events/scheduler.d:51-88,622-650`); schedule firing
  and wake handling use the same worker-owned stores.
- `server.d` is the common authorization/lifecycle layer. It exempts health and hook paths, handles the
  client and MCP capabilities, and gates coordination and run-token requests
  (`source/daemon/server.d:77-109`). Hook payloads are handled by D routes in `hooks.d`; Python `hook.py`
  forwards CLI events to those loopback routes and polls permission decisions
  (`source/daemon/interop/devin/hook.py:14-25,52-83,86-105`).
- The profile store, coordination streams/rooms, pending events, schedules, wake records, executions,
  capability files, and daemon configuration are distinct persisted state. `storage.d` supplies shared
  bounded reads and atomic writes (`source/daemon/storage.d:39-96`); the owning modules define their data
  formats and invoke those helpers.
- The backend boundary is split across the generic `interop.bridge`/`interop.session` abstractions,
  Devin-specific implementation (`interop.devin.bridge`, `acp`, `session`), ACP client/relay protocol
  code, and durable `Execution` records. Session metadata/history are read by `devin.db` from SQLite
  read-only, while execution lifecycle/output are stored by `execution.d`
  (`source/daemon/interop/devin/db.d:12-47,50-95`;
  `source/daemon/interop/execution.d:164-205,278-337,480-510`). `client.d` joins these sources for
  transcript responses (`client.d:152-177`). This describes the present boundaries without equating
  them to a proposed Bridge/Sessions target shape.

## File inventory

### Root modules

| File | Responsibility, imports/dependencies, and side effects | Evidence |
|---|---|---|
| `source/daemon/app.d` | Executable composition root. Imports Serverino and endpoint modules and registers them in `ServerinoMain!`; it contains no route implementation of its own. | `app.d:3-34`; executable config `dub.json:9-15` |
| `source/daemon/package.d` | Public top-level package façade, re-exporting agent, config, exception, interop, and policy APIs. | `package.d:1-7` |
| `source/daemon/server.d` | Serverino lifecycle, health/stop routes, loopback listener, worker runtime lifecycle, common authorization, per-request scheduler refresh, and exception conversion. Stop asks the bridge to stop sessions, then terminates the daemon process. Imports runtime, HTTP helpers, Serverino, POSIX signals, and process/environment APIs. | `server.d:3-14,22-57,59-75,77-140` |
| `source/daemon/runtime.d` | Package-scoped shared runtime references and their initialization/close order. Reads `AUTONOM_CONFIG`, constructs the Devin bridge and stores, starts no thread itself. | `runtime.d:3-23,25-43` |
| `source/daemon/config.d` | Parses/validates YAML settings, resolves paths, parses durations and compaction thresholds, creates the configured Intuit router, and derives the SQLite session DB path. Depends on storage, YAML deserialization, and Intuit router interfaces. | `config.d:3-15,19-115,172-204,214-292` |
| `source/daemon/storage.d` | Shared bounded text/JSON reads and atomic file replacement; uses POSIX descriptor/stat/fsync operations, JSON, and UUID temporary names. It is package-scoped support rather than an endpoint or owning store. | `storage.d:3-15,39-96` |
| `source/daemon/exception.d` | Defines `InvalidInputException`, `ConflictException`, and `BackendException`, all based on `Exception` with standard exception constructors. | `exception.d:1-18` |
| `source/daemon/http.d` | Shared HTTP response/error and method checks, route parameter/path helpers, JSON body/field validation, request-to-`Launch` parsing, and caller/session authorization helpers. Depends on runtime/agent state and Serverino. | `http.d:3-16,16-80,81-187` |
| `source/daemon/client.d` | Read-oriented `/api/client/*` aggregation for profiles/sessions/rooms, messages, pending events, transcripts, and models. Imports agent/coordination/events, execution/session, SQLite-history reader, runtime, and storage; transcript joins a session/execution with DB messages, and model listing invokes `bridge.run`. | `client.d:3-18,22-88,90-145,152-220` |
| `source/daemon/hooks.d` | `/api/hooks/*` handlers for all eight hook events. On `PreToolUse`, derives the directory from authenticated/observed execution or session state, checks policy and unread-event gate, and injects session identity for managed MCP calls; `PermissionRequest` creates a pending permission. Other hook routes return context or acknowledge lifecycle events. Depends on agent, event, execution/session, policy, HTTP, and runtime APIs. | `hooks.d:3-20,29-121,122-196,197-304` |

### `agent/`

| File | Responsibility, imports/dependencies, and side effects | Evidence |
|---|---|---|
| `source/daemon/agent/package.d` | Public façade for `Profile`, reserved `HUMAN_NAME`, `ProfileStore`, conflict type, and name validation. | `agent/package.d:1-4` |
| `source/daemon/agent/profile.d` | `Profile` model and JSON representation, session binding, reserved human name, and the profile-by-name GET route. Depends on session, HTTP, runtime, and Serverino. | `agent/profile.d:3-8,10-23,25-55` |
| `source/daemon/agent/store.d` | Profile listing/create and profile-session binding routes; canonicalizes/validates names and owns in-memory assignments/bindings. Loads current `state.json`, imports legacy per-profile/session mappings when needed, and atomically saves state on mutations; checks bridge/session activity before rebinding. Depends on config, profile, bridge/session, HTTP, runtime, and storage. | `agent/store.d:3-20,24-65,68-92,97-115,138-221,227-400` |

### `coord/`

| File | Responsibility, imports/dependencies, and side effects | Evidence |
|---|---|---|
| `source/daemon/coord/package.d` | Public coordination façade for `Bus`, `Room`, `Entry`, and `Stream`. | `coord/package.d:1-5` |
| `source/daemon/coord/access.d` | HTTP access/validation for rooms, room messages/membership/admins, DMs, and pings. Uses profiles and shared runtime `bus`/events, advances read cursors, and clears matching pending events on reads. | `coord/access.d:3-13,135-159,160-220,221-307,308-357` |
| `source/daemon/coord/bus.d` | Coordinates room and inbox streams, profile cursors, room loading/creation/deletion, and direct/ping delivery. Persists cursors and delegates append/trim behavior to `Stream`; depends on profile store, room/stream, config, and storage. | `coord/bus.d:3-21,35-68,70-126,126-168,168-227,227-321` |
| `source/daemon/coord/room.d` | Room membership/visibility/admin model, with owner/admin/involved profile data stored in `profiles.json` using atomic writes. Depends on profile and storage APIs; it does not own room message streams. | `coord/room.d:3-14,18-77,80-108,122-177` |
| `source/daemon/coord/stream.d` | `Entry` JSON representation and append-only JSONL `Stream`; loads bounded logs, skips malformed entries, maintains an in-memory window, and appends persisted entries. Depends on shared storage plus POSIX file operations. | `coord/stream.d:3-19,21-87,89-142,146-178` |

### `events/`

| File | Responsibility, imports/dependencies, and side effects | Evidence |
|---|---|---|
| `source/daemon/events/package.d` | Public façade for event/store/type, schedule/match/store, and scheduler. | `events/package.d:1-5` |
| `source/daemon/events/event.d` | Pending-event model/store and `/api/events` read-and-clear endpoint. Persists each profile's capped event array under its coordination inbox and can clear by event type/room; tied to `ProfileStore`, config, and stream timestamp units. | `events/event.d:3-15,19-32,34-69,70-109,112-157,159-286` |
| `source/daemon/events/schedule.d` | Schedule model/matching/store plus `/api/schedules`, per-ID deletion, and `/api/schedules/refresh`. Persists per-profile schedules, validates clock/repeating schedules, advances due schedules, and uses coordination/event stores. | `events/schedule.d:3-20,24-80,81-140,180-220,237-283,285-455` |
| `source/daemon/events/scheduler.d` | Wake delivery and background clock thread. Reconciles `wakes.json`, groups pings/room/DM/clock events, chooses resume or fresh-session start, records in-flight execution ownership, registers successful starts, and re-surfaces failed wake events. Depends on profiles, bus, stores, Devin/session/execution metadata and loopback HTTP. | `events/scheduler.d:3-24,28-88,93-195,197-308,351-399,442-639,640-660` |

### `interop/`

| File | Responsibility, imports/dependencies, and side effects | Evidence |
|---|---|---|
| `source/daemon/interop/package.d` | Public façade for generic bridge, Devin bridge/session, execution types, and session types. | `interop/package.d:1-6` |
| `source/daemon/interop/access.d` | Owns client/run/MCP capabilities and managed/trusted-session bookkeeping. Reads/writes managed-session state and per-session MCP token files; mints, admits, revokes, and collects capabilities. Depends on execution/session types, storage, and filesystem/mutex APIs. | `interop/access.d:3-14,18-69,70-120,123-200,201-252` |
| `source/daemon/interop/bridge.d` | Generic abstract backend bridge: canonical session/execution registries, observed-session bookkeeping, bridge command execution/logging, stop/close/collection. Depends on access, execution, session, process and storage layers; it is not the ACP transport executable. | `interop/bridge.d:3-23,25-115,116-180,181-256,256-428` |
| `source/daemon/interop/session.d` | Generic abstract `Session`, statuses/metadata accessors and JSON view, execution binding, and `/api/sessions/*` routes for batch removal, lookup, resume, steer, stop, log, and manage. Routes call the bridge/session APIs and may launch asynchronous executions. | `interop/session.d:3-14,29-72,73-182,183-294` |
| `source/daemon/interop/metadata.d` | `SessionMetadata` value object and JSON serialization for backend session metadata, including model, directory, title, mode, backend, timestamps, hidden state, and workspace list. No persistence or route ownership. | `interop/metadata.d:1-22` |
| `source/daemon/interop/execution.d` | Persisted asynchronous execution record/state machine, output/error logs, background task and dependency sequencing, stop/steer handling, and GET/stop execution endpoints. Depends on process, session/runtime, storage, Serverino, threads and OS process/file APIs. | `interop/execution.d:5-24,28-55,58-111,164-267,274-480,480-631` |
| `source/daemon/interop/process.d` | Child-process helpers: environment-prefix scrubbing, process-group creation, parent-death signal and process signaling/wait support. Used by bridge/execution/ACP paths; no routes or durable domain store. | `interop/process.d:1-15,15-91` |
| `source/daemon/interop/permission.d` | In-memory pending permission requests and list/decision routes; stores copied JSON input, waits for a human decision or expiration, and exposes removals/serialized pending records. Depends on shared runtime and HTTP/Serverino. | `permission.d:3-10,14-57,58-103,104-148` |
| `source/daemon/interop/mcp.d` | Builds/injects the `autonom-coord` MCP server configuration into ACP params; `/api/acp/admit` binds an issued capability to an observed session, and `/api/mcp/session` resolves the session from the MCP capability header. Depends on runtime capabilities and HTTP/Serverino. | `interop/mcp.d:3-12,14-51,52-89,90-104` |
| `source/daemon/interop/acp/package.d` | Public re-exports of ACP client, framing utilities, and relay APIs. | `interop/acp/package.d:1-5` |
| `source/daemon/interop/acp/client.d` | ACP client process/protocol implementation: line-framed JSON-RPC over child pipes, request/response correlation, notifications and delegated agent requests, timeout/poll/disconnect/close behavior. Depends on process helpers and D threads/conditions. | `interop/acp/client.d:3-14,18-50,55-100,100-238,239-455` |
| `source/daemon/interop/acp/frames.d` | ACP frame header scanning, bounded writes, observation taps/queue, and frame direction tracking. Support used by the byte relay and control injection; no HTTP routes. | `interop/acp/frames.d:3-14,16-99,100-182,183-238` |
| `source/daemon/interop/acp/relay.d` | ACP stdio-to-child relay. Forwards frames, observes them, can selectively consume/inject or rewrite frames, and uses bounded framing/process helpers; this is transport behavior, distinct from the daemon's persisted `Execution`. | `interop/acp/relay.d:3-14,16-33,34-100,100-200,284-385,480-499` |

### `interop/devin/`

| File | Responsibility, imports/dependencies, and side effects | Evidence |
|---|---|---|
| `source/daemon/interop/devin/package.d` | Public re-exports of Devin backend and Devin session implementation. | `interop/devin/package.d:1-4` |
| `source/daemon/interop/devin/bridge.d` | Devin-specific `Bridge` implementation and `/api/sessions`, `/api/print`, `/api/acp/observe` routes. Owns CLI configuration, session lock/observed-connection handling, task launch and bridge integration with ACP, capabilities, executions, SQLite metadata and generic session/profile APIs. | `interop/devin/bridge.d:3-31,35-148,149-221,222-386,387-458` |
| `source/daemon/interop/devin/acp.d` | Runs/resumes/cancels a session through the ACP client, injects MCP configuration and capability, applies model/mode options, streams execution result, and can send prompts/config changes through the relay's control socket. Depends on generic ACP, execution, process, storage and access. | `interop/devin/acp.d:3-19,21-63,64-318,319-454,455-509` |
| `source/daemon/interop/devin/session.d` | Devin `Session` adapter: obtains metadata/status from `Devin`, dispatches resume/steer/stop/remove to the bridge, and exposes backend log path. It distinguishes an observed desktop session from a locally executing one. | `interop/devin/session.d:1-8,9-41,43-86` |
| `source/daemon/interop/devin/db.d` | Read-only SQLite adapter for session metadata and conversation history. Queries session rows and the selected main message chain; rejects a non-regular file or symlink. Depends on `arsd.sqlite` and `SessionMetadata`; it does not write the backend DB. | `interop/devin/db.d:3-8,12-47,50-95,98-108` |
| `source/daemon/interop/devin/hook.py` | Python Devin hook process: maps the eight hook event names to daemon endpoints, sends loopback HTTP without proxy use, reads session MCP token, enforces payload/reply limits, and polls permission decisions. Its exception path blocks sensitive hook events. | `interop/devin/hook.py:9-25,32-83,86-105,108-154` |
| `source/daemon/interop/devin/stub.py` | Desktop stale-registry compatibility shim that `execv`s a fixed installation path for `bin/autonom-acp` and supplies a fixed config path; this is a local deployment-specific runtime shim. | `interop/devin/stub.py:1-8` |

### `policy/`

| File | Responsibility, imports/dependencies, and side effects | Evidence |
|---|---|---|
| `source/daemon/policy/package.d` | Public re-export of `Policy` and `PolicyResult`. | `policy/package.d:1-3` |
| `source/daemon/policy/access.d` | `/api/policy/check`, result representation, and policy evaluation using one configured Intuit router. Loads workspace rules, applies first-match allow/deny/screen decisions, bounds screening time, and clears router context on request paths. | `policy/access.d:3-15,19-58,59-107,108-156` |
| `source/daemon/policy/rule.d` | Parses `.devin/policy.yml`, validates rule/action/match fields, compiles regular expressions, and matches tool plus input fields. Depends on YAML, storage and Intuit decision types; no endpoint or persistent policy cache. | `policy/rule.d:3-13,17-27,28-181,182-262` |

### `relay/`

| File | Responsibility, imports/dependencies, and side effects | Evidence |
|---|---|---|
| `source/daemon/relay/package.d` | `autonom-acp` executable entrypoint: loads optional config/client token, creates `RelayAgent`, scrubs inherited capability variables, launches `devin acp` through `runRelay`, forwards frame observations and injection, then closes agent. Separately compiled from daemon `app.d`. | `relay/package.d:1-12,14-75`; executable config `dub.json:41-52` |
| `source/daemon/relay/agent.d` | Per-ACP-connection observer/capability coordinator. Rewrites/injects ACP frames, observes session lifecycle, posts observations/admissions to daemon HTTP, manages heartbeat and authenticated Unix control socket, and scrubs/owns connection-level state. Depends on ACP injection/MCP and relay control modules plus sockets/threads/HTTP. | `relay/agent.d:3-20,22-72,74-167,168-260,261-438,439-670` |
| `source/daemon/relay/control.d` | Relay control injection queue and socket-side request/reply coordination for prompt/cancel/config-option frames; reserves wire IDs and enforces bounded queues. Implements the ACP `RelayInjection` interface and calls back into `RelayAgent`. | `relay/control.d:3-10,12-24,26-60,61-176,177-309` |

## Test references

These tests are outside `source/daemon/` and are not part of the inventory above. They establish directly
exercised behavior: agent/profile persistence and binding (`source/tests/profile.d:20-279`); config
validation (`source/tests/config.d:12-172`); coordination streams/rooms (`source/tests/coord.d:30-238`);
event/schedule/wake flows (`source/tests/events.d:168-526`); ACP framing, client, relay, and control
(`source/tests/acp.d:92-514`); generic bridge (`source/tests/bridge.d:18-97`); SQLite metadata/history
(`source/tests/database.d:30-101`); session/execution lifecycle (`source/tests/session.d:25-314`);
permissions (`source/tests/permission.d:8-33`); policy (`source/tests/policy.d:81-407`); and
server/hooks, client-facing aggregation, capability admission, and integrated coordination flows
(`source/tests/daemon.d:158-951`). `source/tests/common.d` provides shared daemon/agent fixtures and test
helpers (`source/tests/common.d:1-135`).
