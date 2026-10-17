# Daemon architecture and source cutover

The daemon runs one persistent Serverino worker. `daemon.runtime` owns the
bridge, profiles, coordination streams, pending events, schedules, and policy.
HTTP handlers validate inputs and invoke those owners. CLI child work runs in
monitor threads; human permission waits never occupy the HTTP worker.

## Sessions and calls

`Bridge` owns canonical `Session` handles. Session discovery reads the CLI's
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
