# Daemon architecture and source cutover

The daemon runs one persistent Serverino worker. `daemon.api` owns the
bridge, profiles, coordination streams, pending events, schedules, and policy.
HTTP handlers validate inputs and invoke those owners. CLI child work runs in
monitor threads; human permission waits never occupy the HTTP worker.

## Sessions and calls

`daemon.interop.provider.IProvider` is the session boundary used by profiles and
scheduling. `daemon.interop.devin.bridge.Bridge` owns canonical Devin `Session`
handles; `interop/devin/session/` owns their controls, HTTP routes, permissions,
and transcript queries.
Root `interop/` contains provider-neutral identity, calls, access, and protocols. Session discovery reads the CLI's
SQLite database read-only; it does not grant control. A foreign session lock
means loaded elsewhere, not active generation. Profiles retain assignments to
canonical handles independently of discovery and admission.

`GET /api/sessions` returns session objects from the database plus provisional
live sessions. Optional `directory` and `acp=autonom` filters select workspace
and persisted connector metadata. Unmarked sessions have unknown origin;
explicit adoption grants control without inventing historical provenance.
New/load requests stamp `_meta["autonom/connector"]` for future discovery.

`Call` represents current asynchronous child work. Existing `/api/executions`
routes expose call outcomes while their in-memory tickets remain available.
Settled tickets expire after five minutes or when the registry exceeds 128
entries; at most eight calls run concurrently. Call tickets are not durable
history. Existing configuration, data, CLI sessions, and session/output/error
logs are preserved. Old execution JSON files are left intact and are not
loaded as evidence of running work. Uncertain wakes are reconciled without
blindly replaying prompts.

When compaction is requested, `/compact` completes on the loaded ACP connection
before the resume prompt is sent. Failure or cancellation prevents delivery of
that prompt. `compactOnResume` and `offlineCompactAfter` select when to compact;
`compactionThresholds` has been removed. Remove that obsolete key from a
configuration before starting this revision. Source development does not edit
installed configuration automatically.

## ACP and permissions

`FrameReader` decodes newline-delimited JSON-RPC with a 16 MiB frame budget.
Unknown members are preserved semantically; whitespace and object key order
are not preserved. `AcpClient` owns one child stream and one correlation map
for native and daemon requests, with at most 256 outstanding outgoing requests.
Routing changes only a copied envelope's ID, retaining the original identity
for replies. Child stderr stays separate from protocol stdout.

`autonom-acp` remains the small stdio entrypoint used by Desktop. `Desktop`
uses the same connection and a private authenticated Unix socket for daemon
control. Its HTTP observation heartbeat currently supplies cross-process
liveness. MCP admission happens before successful new/load replies reach the
native client. Replacing this topology with daemon-hosted ACP is a separately
sequenced change tracked in Linear ANM-59.

Pending permissions belong to the connection. Native Desktop and authorized
HTTP decisions settle the same request once. `GET /api/sessions/<id>/permissions`
lists offered options and IDs; adding `?id=<request-id>` retrieves full context.
`POST` accepts `{"id":123,"optionId":"offered-option"}` or a null option to
cancel. Only offered options are valid. Pending requests are bounded to 64 and
16 MiB in aggregate, expire after 240 seconds, and are invalidated on disconnect.
API-only sessions wait for an explicit decision until their deadline.

`PreToolUse` continues to enforce policy for automatic and bypassed calls.
Human approval uses native ACP and HTTP. The authenticated `PermissionRequest`
hook returns an empty response; it does not maintain a second approval queue.

## Validation and deployment

Run the commands in [AGENTS.md](../AGENTS.md). Model simulation establishes
protocol and lifecycle behavior; isolated real CLI integration establishes the
tested database/metadata contract. Neither proves native Desktop presentation.

The source cutover was explicitly authorized with live compatibility unverified.
The pinned build was re-based to the installed Desktop commit without live
re-validation. Native UI behavior,
hook/ACP permission coverage, and representative large-history loading remain
open acceptance gates. Installed registry/configuration cutover has not been
performed. Follow the [Desktop contract](COMMAND_CENTER.md) and
[validation procedure](COMMAND_CENTER_VALIDATION.md) before deployment or live
validation. Do not weaken the pin or integrity checks to close those gates.

## Bounded execution and transcript retention contract

The daemon enforces deterministic bounds on stream storage, in-memory call execution tickets, and durable transcript history while guaranteeing live stream continuity and offline wake survivability.

### On-disk stream bounding and single-generation rolling archive

Coordination rooms and DM streams (`daemon.coord.stream.Stream`) enforce a strict on-disk rolling retention contract:
- When an active JSONL log file reaches `maxStreamBytes` (default: 4 MiB) or the number of logged entries reaches `maxStreamEntries` (default: 1,000), it rotates to a single archive generation (`<path>.1`). Any pre-existing `<path>.1` file is atomically replaced.
- Total on-disk footprint per stream is strictly bounded to `2 * maxStreamBytes`.
- In-memory stream `window` is preserved across rotations, guaranteeing that live consumers and reading cursors are never corrupted.
- On startup/reload, the stream reads the `.1` archive tail and active log to reconstruct the in-memory tail window, ensuring that durable room cursors and client positions remain valid across daemon restarts.
- Rotation and read paths enforce symlink verification (`isSymlinkSafe`); attempting rotation into a symlinked destination immediately aborts with an exception, preventing symlink traversal attacks.

### Deterministic LRU call eviction

Child execution tickets in `Bridge` (`daemon.interop.devin.bridge`) are collected deterministically:
- Settled calls (`!call.running`) are sorted by their settlement timestamp (`call.settled` `MonoTime`).
- When total tracked executions exceed `callCapacity` (default: 128) or when a call has been settled longer than `callSettleTimeout` (default: 300 seconds), oldest settled calls are evicted from memory first.
- **Invariant**: Running calls (`call.running`) are NEVER evicted under any circumstances, even when capacity is exceeded.
- Eviction from in-memory tracking automatically persists the execution metadata into the durable index before removal.

### Durable transcript resolution and fallback

Execution lookups remain durable even after in-memory ticket eviction:
- `Bridge` persists execution metadata into `executions/index.json` (bounded to 10,000 entries) and maps execution IDs to session IDs.
- The client transcript endpoint (`GET /api/client/transcript/<id>`) resolves historical execution IDs via the durable index, looking up the associated session and conversation history.
- If the CLI SQLite database returns empty conversation messages, transcript resolution falls back to inspecting on-disk logs (`executions/<id>.out`, `executions/<id>.err`, and `sessions/<session>.log`), preventing premature 404s or empty transcript views.

### Wake event retention

In `daemon.events.scheduler`, offline agent pings that lack a recorded sender workspace are no longer silently discarded with an early return. Instead, batch events are surfaced directly into `events.surface(profile, event)`, ensuring that scheduled wakes, reminders, and offline pings are reliably surfaced to agents upon next connection.

### Retention configuration knobs

Configuration parameters in `daemon.config.DaemonConfig` support both human-friendly units (e.g. `4 MiB`, `10m`) and raw numbers, with backward-compatible defaults:
- `maxStreamBytes`: maximum active stream file size before rotation (default: `4194304` = 4 MiB).
- `maxStreamEntries`: maximum active stream entry count before rotation (default: `1000`).
- `callCapacity`: maximum in-memory call execution tickets before LRU eviction (default: `128`).
- `callSettleTimeout`: duration after settlement before call eviction (default: `300s`).
- `maxConcurrentCalls`: maximum concurrent active calls allowed (default: `8`).
- `pruneExecutionArtifacts`: whether to prune child execution log artifacts (default: `false`).
- `allowDestructivePruning`: whether destructive pruning is permitted (default: `false`).
