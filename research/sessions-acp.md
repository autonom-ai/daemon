# Sessions and ACP: current behavior

**Repository state audited:** `08a8af4` (`interactive-acp`). This records the implementation at that
HEAD, not a proposed design.

The HEAD commit, “Bind coordination access to session-scoped MCP capabilities,” adds the relay
admission path and session-bound MCP token flow described below
[source/daemon/relay/agent.d:494-527,564-622; source/daemon/interop/mcp.d:52-103;
source/tests/daemon.d:879-945].

## Ownership and identifiers

| Thing | Current owner and role |
| --- | --- |
| Backend session data | Devin CLI owns session IDs and the session database. `SessionMetadata` is a value
  object, not the session handle: it carries model, directory, title, mode, backend, timestamps,
  hidden state, and workspace directories [source/daemon/interop/metadata.d:7-18]. |
| Session handle | `Bridge` caches one backend-specific `Session` per ID; `DevinSession` delegates
  metadata, status, resume, steer, stop, removal, and log behavior to `Devin`
  [source/daemon/interop/bridge.d:149-173; source/daemon/interop/session.d:193-294;
  source/daemon/interop/devin/session.d:9-86]. IDs are copied and validated before being retained
  [source/daemon/interop/session.d:207-223]. |
| Execution | The daemon owns a separate UUID-keyed `Execution` for one task/process lifecycle. Its
  record carries an optional backend `sessionId`, kind, workspace, model, timestamps, status,
  result/error, profile, mode, and trust; records are written under the execution directory
  [source/daemon/interop/execution.d:90-101,164-188]. An execution is not a session handle. |
| CLI operations | `Devin` invokes `devin acp` for start, print, resume, and compact tasks; removal
  uses `devin rm --force -- <id>`. Backend listing is a separate synchronous
  `devin list --format json` call (the CLI helper defaults to a two-second timeout)
  [source/daemon/interop/devin/bridge.d:207-218,359-380,400-449;
  source/daemon/interop/bridge.d:407-450;
  source/daemon/interop/devin/acp.d:64-96]. |
| CLI database | `sessionDatabase` resolves to `sessions.db` beside the configured session-lock
  directory [source/daemon/config.d:189-195,287-290]. `devin.db` opens it read-only and queries metadata by
  session ID; it separately follows `main_chain_id` for transcript messages
  [source/daemon/interop/devin/db.d:12-48,50-96]. The database path shown here is not an execution-record store. |

The API exposes more than one notion of a session list. `GET /api/sessions` returns
`bridge.sessionIds()` [source/daemon/interop/devin/bridge.d:35-43]. That method unions IDs in the managed-access registry
with IDs currently observed from ACP connections [source/daemon/interop/bridge.d:272-280]. It does not call
`Devin.list()`. A detail lookup uses `findSession()`, which returns an already-cached handle or
creates one for a currently observed ID; it otherwise returns null [source/daemon/interop/bridge.d:160-173].

The richer Command Center state response iterates the same IDs, resolves a handle, skips unresolved
handles, serializes each `Session`, and adds its profile; an execution workspace supplies a
directory only when the serialized directory is empty [source/daemon/client.d:56-71]. `Session.toJSON()` calls
the metadata accessor and adds status, exit status, and the current execution ID. If no database
row supplied an ID, it fills model/mode/directory from the attached execution
[source/daemon/interop/session.d:277-293].
`Devin.sessionMetadata()` suppresses database-read exceptions into empty metadata and, for an
observed session with no database ID or directory, supplies only its ID and observed directory
[source/daemon/interop/devin/bridge.d:386-402].

The transcript endpoint resolves either a session ID or execution ID; a direct session-ID lookup
requires managed status. It reads database messages for the resolved session and includes the
associated execution when present; if there are no messages and the execution has completed, it can
show the execution output as an assistant message [source/daemon/client.d:152-195]. The database
reader follows the main chain, caps the depth/message size/total bytes, and excludes system-role messages
[source/daemon/interop/devin/db.d:50-96].

## API and execution flow

```text
POST /api/sessions
  -> sessions endpoint reads Launch
  -> Devin.start -> submit -> Execution + acpTask
  -> child `devin acp`; initialize; session/new
  -> identify returned session ID; inject prompt; monitor ACP replies
  -> Execution record/result and Session handle

GET /api/sessions
  -> Bridge.sessionIds (managed IDs + relay-observed IDs)
GET /api/sessions/<id>
  -> Bridge.findSession -> Session.toJSON -> DevinSession.metadata
  -> read-only CLI database lookup by ID (with fallbacks above)
```

`submit()` validates the prompt, directory, model, and mode. For an existing ID it reads metadata
to default model and mode, then creates an execution and delegates it to `acpTask`
[source/daemon/interop/devin/bridge.d:400-449]. `acpTask` launches the configured command with `"acp"`, initializes an
`AcpClient`, sends `session/load` for an existing ID or `session/new` otherwise, identifies the
new ID, applies options, sends the prompt, and collects message chunks and the terminal result
[source/daemon/interop/devin/acp.d:77-96,158-201,228-315]. The execution thread persists lifecycle state separately
from the session metadata [source/daemon/interop/execution.d:207-266,399-430].

`GET /api/client/transcript/<id>` may take either a session ID or execution ID; in the latter case
it resolves the execution's session ID [source/daemon/client.d:152-165]. The CLI's `list` method is implemented
and tested, but the HTTP ID-list route above uses the bridge registry instead
[source/daemon/interop/devin/bridge.d:359-380; source/tests/bridge.d:33-42].

## Managed and externally created sessions

**Daemon-launched / managed path.** `POST /api/sessions` starts a task and returns its execution
record with HTTP 202 [source/daemon/interop/devin/bridge.d:35-70]. The task mints a run capability and injects an
`autonom-coord` MCP server in `session/new`/`session/load` parameters. After the backend returns
the session ID, it binds the MCP capability to that ID [source/daemon/interop/devin/acp.d:170-196]. The run capability
can bind a starting execution to the new ID; when an execution is collected, start or print IDs
that have a session ID are remembered in the persistent managed registry
[source/daemon/interop/access.d:95-120; source/daemon/interop/bridge.d:305-347].
`POST /api/sessions/<id>/manage` is another route that records an ID as managed
[source/daemon/interop/session.d:171-181]. The registry is stored in `managed.json`
[source/daemon/interop/access.d:18-60,123-139].

**Externally created / Desktop ACP path.** `bin/autonom-acp` runs the relay wrapper around
`devin acp`. With a valid config it creates a connection UUID, reads the daemon client token,
starts a Unix control socket, and enables observation and rewrite callbacks; without usable
configuration it reports control disabled and runs without those callbacks
[source/daemon/relay/package.d:14-74]. The relay rewrites external `session/new` and `session/load` request
frames to inject the MCP server and a fresh token. On the matching response, `RelayAgent` records
the session and calls `/api/acp/admit`; the daemon validates the admission, binds the token,
remembers the session, and exposes token-to-session resolution through `/api/mcp/session`
[source/daemon/relay/agent.d:494-527,564-622; source/daemon/interop/mcp.d:52-103].

The relay reports its session IDs, directories, and active state to `/api/acp/observe` on a
10-second heartbeat. The daemon treats each report as authoritative for that connection, removes
sessions omitted from the report, and `sweepObserved()` removes connections older than 30 seconds
when invoked (per-request refresh calls the sweep); it also revokes the MCP capability when an
observed entry is dropped [source/daemon/relay/agent.d:24,120-166,210-225;
source/daemon/interop/devin/bridge.d:84-146; source/daemon/interop/bridge.d:40-45,205-269;
source/daemon/server.d:111-115]. Admission also calls `access.remember()`, while dropping an
observation revokes the MCP token but does not call `access.forget()` [source/daemon/interop/mcp.d:80-87;
source/daemon/interop/bridge.d:40-45]. Thus “managed”
and “currently observed” are separate flags/registries, and an externally created, admitted
session can remain managed after its relay observation expires.

For a currently observed session, `resume` and `steer` are routed through the owning relay's Unix
socket; stop sends `session/cancel`. The session API permits resume/steer only for managed or
observed IDs, and rejects removal of an observed session (or a session with a foreign held lock)
[source/daemon/interop/session.d:89-115,118-137; source/daemon/interop/devin/bridge.d:207-218,235-321;
source/daemon/interop/devin/session.d:43-76]. The same
`DevinSession` API therefore covers daemon-owned executions and relay-observed sessions, while
the underlying control path differs.

## ACP relay and tap layers

These directories contain two cooperating layers, not two names for the same class:

| Layer | Current responsibility |
| --- | --- |
| `source/daemon/relay/package.d` | Executable wrapper: selects the Devin command/configuration, builds a `RelayAgent`, scrubs inherited ACP/Autonom capability variables from the child, and invokes `runRelay` with observer, injection, and (when linked) rewrite callbacks [source/daemon/relay/package.d:14-75]. |
| `source/daemon/interop/acp/relay.d` | Stdio/process transport: starts the child with pipes and uses two threads to forward client-to-child and child-to-client bytes. It handles line boundaries, bounded writes, optional request rewriting, queued frame injection at aligned boundaries, and matching reply consumption [source/daemon/interop/acp/relay.d:31-60,96-150,282-425,480-499]. |
| `source/daemon/interop/acp/frames.d` | `FrameTap` assembles newline-delimited observed frames and `FrameQueue` hands them to an observer thread. The tap does not rewrite the stream. A frame is discarded at the 2 MiB tap limit; the queue silently declines frames after 64 queued items [source/daemon/interop/acp/frames.d:13-14,135-173,183-237]. `scanHeader()` identifies a top-level JSON-RPC ID/method prefix for relay-control response matching [source/daemon/interop/acp/frames.d:16-98]. |
| `source/daemon/relay/agent.d` | Per-connection observer/admission state: request-ID tracking, session IDs/directories, prompt activity, issued MCP tokens, heartbeat POSTs, and request-frame rewriting for `session/new`/`session/load` [source/daemon/relay/agent.d:74-100,120-193,447-622]. |
| `source/daemon/relay/control.d` | Implements `RelayInjection` and the authenticated Unix control endpoint. It queues injected ACP calls, reserves response IDs, consumes the matching child reply, and returns the result to the socket caller; it validates the token, supported method, and session membership [source/daemon/relay/control.d:75-85,186-276,322-435]. |
| `source/daemon/interop/acp/client.d` and `source/daemon/interop/devin/acp.d` | Separate in-process ACP client for daemon-launched CLI tasks: starts `devin acp`, parses JSON-RPC lines, correlates responses, handles notifications and agent requests, and manages child shutdown [source/daemon/interop/acp/client.d:100-145,453-546,552-601,604-760; source/daemon/interop/devin/acp.d:77-96,98-156]. It is not the Desktop stdio relay. |

`runRelay()` is a byte-stream proxy rather than an ACP object dispatcher: its transport reads and
writes arbitrary chunks, while newline framing is applied only where observation, rewriting, or
injection requires it. When a rewriter is supplied, the client-to-agent path buffers candidate
session-creation/load lines; other lines are forwarded. The observer sees forwarded bytes through
the tap queue, while the injection path may hold a matching response until `RelayControl` delivers
it to its Unix-socket caller [source/daemon/interop/acp/relay.d:141-278,302-425;
source/daemon/interop/acp/frames.d:135-237].

The tap and request/reply path have distinct failure/limit behavior: observation frames can be
silently dropped by the tap cap or full queue, whereas an injected reply exceeding the consume
limit returns a control error (`-32603`). The current constants are a 2 MiB observed-frame cap,
64-frame observation queue, 8 KiB decision/header prefix, and 4 MiB consumed-frame limit
[source/daemon/interop/acp/frames.d:13-14,164-169,203-205;
source/daemon/interop/acp/relay.d:482-488; source/daemon/relay/control.d:238-246].

## Tests: demonstrated behavior and boundaries

| Tests | What they exercise |
| --- | --- |
| `source/tests/bridge.d:18-42,75-97` | A canonical handle is reused and shared with a profile; CLI list parses IDs; removal invokes the CLI and removes its log. |
| `source/tests/database.d:30-54,57-80,83-101` | Metadata values reflect SQLite rows and updates; history follows the main chain and excludes system/abandoned messages; a database symlink is rejected. |
| `source/tests/session.d:113-151,190-228,230-247` | ACP resume uses `session/load`, requested model, and literal prompt; host variables are scrubbed; an agent turn can fail while its process exit status is zero. |
| `source/tests/acp.d:92-145,148-197` | Relay byte forwarding/exit status and selective session-frame rewriting while other frames remain unchanged, including a large load request. |
| `source/tests/acp.d:199-245,248-378` | MCP-server replacement/preservation, ACP client request/notification/cancel behavior, permission replies, and unknown-method errors. |
| `source/tests/acp.d:380-514` | End-to-end relay control socket rejects a wrong token and unknown session, injects a prompt, returns its result, and queues cancellation. |
| `source/tests/daemon.d:879-945` | Admission validation, token-to-session lookup, persisted token file, coordination access bound to that session, hook session injection, and revocation when the observation closes. |

Those tests establish the listed examples; they do not establish queue/size-limit behavior under
load, coverage of arbitrary ACP peers or frame encodings, or which session population the public
session catalog is intended to represent.

## Open questions and tradeoffs (not resolved here)

- **Catalog source and meaning:** should a “listable session” mean an ID in the managed/observed
  bridge registry, a CLI `list` result, a database row, or some combination? Current code exposes
  these as distinct mechanisms: `GET /api/sessions` uses the registry, `Devin.list()` invokes the
  CLI, and metadata queries address one database ID
  [source/daemon/interop/devin/bridge.d:35-43,359-380; source/daemon/interop/devin/db.d:12-48].
  The current boundaries do not specify how foreign, unobserved CLI/database sessions enter the
  richer `Session` view.
- **List/lookup consistency:** the ID union includes `access.ids`, but `findSession()` only resolves
  cached or currently observed handles. Profile restoration creates handles for bound sessions;
  managed IDs not otherwise cached are not constructed by `findSession()` itself
  [source/daemon/interop/bridge.d:149-173,272-280; source/daemon/agent/store.d:187-203]. Whether list and detail/state views must have
  identical membership is not specified by these paths.
- **Metadata authority and absence:** when the database has a row, its fields take precedence;
  execution launch values fill model/mode/directory only when the metadata ID is empty. Database
  errors become empty metadata, with only observed ID/directory fallback. The desired behavior for
  partial rows, missing database files, or metadata that disagrees with execution launch values is
  not asserted by the current tests [source/daemon/interop/session.d:277-293;
  source/daemon/interop/devin/bridge.d:386-402].
- **Meaning of managed after observation:** ACP admission persists managed membership, but relay
  loss removes the observed connection and revokes MCP without forgetting that membership. The
  status/access semantics intended for this post-disconnect state are not stated
  [source/daemon/interop/mcp.d:80-87; source/daemon/interop/bridge.d:40-45,205-269].
- **Relay/tap abstraction boundary:** the current byte proxy must accommodate partial reads/writes,
  newline frame assembly, request rewriting, injection at boundaries, reply-ID correlation,
  observer delivery, and bounded/drop behavior. It remains an open tradeoff which of these
  guarantees a simpler packet/frame model would own and how overload, oversized frames, or
  control-response matching should behave; the tests cover representative forwarding and injection,
  not those boundary cases [source/daemon/interop/acp/relay.d:96-150,282-425;
  source/daemon/interop/acp/frames.d:135-237; source/daemon/relay/control.d:199-246].

One documentation discrepancy at this audited HEAD: `AGENTS.md:20` describes execution records as
version 2, while `Execution.record()` writes version 3 and the loader accepts versions 1, 2, and 3
[source/daemon/interop/execution.d:164-188,480-546]. The source behavior is cited above; the discrepancy is recorded
without changing either contract here.
