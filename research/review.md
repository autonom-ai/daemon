# Architecture Research Review

## Scope and snapshot

This is a research record, not a refactor proposal. It records what the checked-in
code does and what the current interfaces require so later decisions can be made
against the same evidence. It deliberately makes no keep/remove/merge decisions
and offers no implementation plan.

- Repository: `/home/cet/Repos/autonom`
- Branch: `interactive-acp`
- Audited revision: `08a8af4bb4321021c3f4ef4f167ea14d55c23dc1`
- Revision date: 2026-10-16
- Tracked baseline at that revision: 118 files (111 text files, excluding SVG
  files and the launcher lockfile from the text count).
- The worktree was clean when this research began. The only implementation-tree
  change in this work is a narrow `.gitignore` exception that makes the requested
  research documents visible to Git.

The file inventories in [daemon-map.md](daemon-map.md) and
[repo-map.md](repo-map.md) cover every tracked file at the audited revision.
The focused investigations are [sessions-acp.md](sessions-acp.md) and
[permissions.md](permissions.md). The earlier style study has been superseded
by the corrected [Autonom code style](style-rules-revision.md).

## Lens from the request

The user describes the desired conceptual boundary as: the interop bridge owns
CLI/session execution, the CLI database supplies session metadata, and the
bridge lists `Session` objects. They also question whether the ACP relay/tap
system, the permission queue's separate state, the Bash/Python installer entry,
and the current conventions guide reflect that boundary.

These are questions to investigate, not conclusions adopted by this document.
In particular, removing or collapsing a component is not assumed to preserve
the behavior that currently crosses it.

## Observed session and metadata ownership

Session identity is represented in several places, each with a different
lifetime or responsibility:

| Representation | Current responsibility | Evidence |
| --- | --- | --- |
| Devin CLI `sessions` database | Read-only source for backend metadata, including model, workspace, title, mode, timestamps, hidden state, and workspace list; the same adapter reads a session's main conversation chain. | `source/daemon/interop/devin/db.d:12-108` |
| Interop `Session` / `DevinSession` | Per-ID facade for status, metadata, execution binding, resume, steer, stop, remove, and log lookup. Metadata delegates to the Devin bridge. | `source/daemon/interop/session.d:183-294`; `source/daemon/interop/devin/session.d:9-86` |
| Interop `Bridge` session/execution maps | Caches session handles and executions; also owns managed-session admission and relay-observed connection state. | `source/daemon/interop/bridge.d:27-40,150-203,206-260` |
| Interop `Access` managed-session map | Persists recognized session IDs and their `trusted` flag in `managed.json`; also owns daemon-client, execution-run, and MCP capabilities. | `source/daemon/interop/access.d:23-68,76-121,123-139,144-208,242-252` |
| Agent profile store | Persists profile-to-session assignment, separately from backend session metadata and access admission. | `source/daemon/agent/store.d` |
| ACP relay's observed-session map | Tracks IDs, directories, active status, and a connection ID reported by a relay heartbeat. | `source/daemon/interop/bridge.d:27-40,206-260`; `source/daemon/relay/agent.d` |

At this revision, both `GET /api/sessions` and `/api/client/state` enumerate
`Bridge.sessionIds()`. The former returns the IDs; the latter constructs a
`Session` for each ID and adds its metadata and profile. `sessionIds()` unions
IDs from the managed `Access` map and the relay-observed map; neither route
asks the Devin CLI to discover all session IDs or reads the database as an
inventory. `Devin.list()` separately implements `devin list --format json`,
but a tracked-source call-site search found no caller for it. Thus a CLI
session that is neither in the managed map nor observed by a relay is not in
these two bridge-backed listings, even if a CLI database row exists.
Evidence: `source/daemon/interop/devin/bridge.d:35-72,359-383`;
`source/daemon/interop/bridge.d:272-281`; `source/daemon/client.d:56-70`;
the tracked-source reference search.

The database provides descriptive state, not execution lifecycle state. It does
not replace an execution's cancellation, error, result, exit status, timeout,
process, output, or recovery state. Those fields belong to the separate
`Execution` record and its monitor. Conversely, `Execution` carries launch
metadata such as workspace/model/mode and trust/profile context, and its
top-level TODO says its records may eventually be replaced by the CLI database.
The present SQLite queries do not read those execution lifecycle fields.
Evidence: `source/daemon/interop/execution.d:1-4,59-87,91-115,165-193`;
`source/daemon/interop/devin/db.d:12-48`.

`Execution` currently writes version-3 records and reads versions 1, 2, and 3;
the version coverage is explicitly exercised by a test. The current
`AGENTS.md`, however, describes version 2 with version 1 as the older format.
`ExecutionKind.Acp` also remains a parseable record value, but no tracked
production call site constructs that kind.
Evidence: `source/daemon/interop/execution.d:59-67,123-141,165-181`;
`source/tests/session.d:283-314`; `AGENTS.md:20`.

The abstraction chain is currently single-backend in checked-in source:
`Bridge` is abstract and its implementation is `Devin`; `Session` is abstract
and its implementation is `DevinSession`. No second bridge or session
implementation appears in the tracked tree. The HTTP route mixins are split
across the abstract execution/session modules and the Devin implementation
module, while the runtime stores a concrete `Devin`.
Evidence: `source/daemon/interop/bridge.d:24-48`;
`source/daemon/interop/session.d:212-230`;
`source/daemon/interop/devin/bridge.d:149-176`;
`source/daemon/interop/devin/session.d:9-22`;
`source/daemon/runtime.d:1-38`;
`source/daemon/app.d:19-34`.

## Observed execution and ACP ownership

The managed CLI path and the Desktop-observed path are not the same process
model:

1. Managed start/resume/print calls create an `Execution` and invoke an
   `ExecutionTask`. Devin's task launches `devin acp` through `AcpClient`.
   The daemon records process/result state and exposes it through execution and
   session endpoints. `Execution` persists records and logs and runs monitoring
   outside the single Serverino request worker.
   Evidence: `source/daemon/interop/devin/bridge.d:149-176,326-451`;
   `source/daemon/interop/devin/acp.d:63-157`;
   `source/daemon/interop/acp/client.d:37-212`;
   `source/daemon/interop/execution.d:278-460`.
2. A relay for a Desktop-owned ACP process observes its `session/new` and
   `session/load` traffic, reports sessions to the daemon, and offers separate
   `session/prompt`, `session/cancel`, and configuration-option control over a
   private Unix socket. Those sessions are not the daemon's child process.
   Evidence: `source/daemon/relay/package.d:1-75`;
   `source/daemon/relay/agent.d`; `source/daemon/relay/control.d`;
   `source/daemon/interop/devin/bridge.d:84-148`;
   `source/daemon/interop/devin/acp.d:318-456`.

ACP transport already has newline-delimited JSON frames in the subprocess
protocol. `AcpClient` parses/writes those messages and correlates requests by
ID; the relay path preserves the byte stream, scans relevant JSON-RPC fields,
can rewrite selected session initialization/load frames, forwards bounded
chunks, queues bounded observations, and supports control injection.
The relay and `interop/acp` both contain code named for relay/control/tap
behavior, but they serve different parts of the stream/observation/control
path. Whether all these pieces can be represented by a simpler packet/frame
model depends on which observation, injection, and transparent-forwarding
behaviors are in scope; this investigation makes no such design choice.
Evidence: `source/daemon/interop/acp/client.d:37-212`;
`source/daemon/interop/acp/frames.d:13-238`;
`source/daemon/interop/acp/relay.d`;
`source/daemon/relay/agent.d`;
`source/daemon/relay/control.d`.

Build configuration includes the relay sources in the separate `relay`
configuration and explicitly excludes `source/daemon/relay/**` from the
daemon configuration. Unit setup builds both configurations. This is a real
packaging/runtime boundary, in addition to the source-module boundary.
Evidence: `dub.json:1-70`.

## Permission path and ownership

`PermissionRequest` is a blocking host-hook exchange, distinct from
`PreToolUse` policy screening. The daemon accepts the hook, copies a pending
request into an in-memory map, responds with an ID, and later serves the hook's
session-bound polling GET. A human client can list pending requests and submit
an explicit `approve` or `block` decision. The Python hook waits outside the
Serverino request worker and turns expiry/failure into a block response.
Evidence: `source/daemon/hooks.d:246-263`;
`source/daemon/interop/permission.d:14-148`;
`source/daemon/interop/devin/hook.py:87-105`;
`templates/hooks.v1.json:1-8`;
`source/daemon/server.d:77-109`.

At this revision `permission.d` is 148 lines and has exactly two in-memory
types, `PermissionStore` and `Permission`. Each request retains its generated
ID, session ID, tool name, cloned tool-input JSON, creation time, and a
decision string. It is neither persisted nor attached to the `Session` object.
The session field binds later polling to the originating session; the tool and
input are returned to the human client; creation time supports a 240-second
expiry. The clone is explicitly covered by a test for reused/mutated input.
The queue prunes expired records on a new add and caps currently stored
requests at 64. These facts bound which data is candidate state and why each
field is currently present; they do not decide which UI/product behavior is
necessary.
Evidence: `source/daemon/interop/permission.d:58-148`;
`source/tests/permission.d:8-33`;
`source/mcp/tests.py:155-162`.

## Other cross-cutting state and boundaries

- There is one Serverino worker for mutable registries; runtime construction
  wires the bridge, profile store, coordination bus, event/schedule stores,
  scheduler, policy, and permission store. Execution workers and scheduler
  threads are separate mechanisms with separate owners.
  Evidence: `source/daemon/server.d:59-75,111-134`; `source/daemon/runtime.d:1-44`;
  `AGENTS.md:14-22`.
- Authentication is not one undifferentiated session check. The server accepts
  daemon-client, execution-run, session, and MCP credentials on different
  routes. The current revision's commit binds coordination access to a
  session-scoped MCP capability; the token lookup resolves the session rather
  than trusting a client-provided session ID.
  Evidence: `source/daemon/server.d:77-109`;
  `source/daemon/interop/access.d:70-87,88-121,123-250`;
  `source/daemon/interop/mcp.d:21-104`;
  `source/daemon/interop/devin/hook.py:42-78`.
- Coordination authorization and durable profile ownership are related but
  separately stored. The bridge's session admissions do not by themselves
  describe room membership, schedule ownership, event cursors, or a profile's
  permanent assignment.
  Evidence: `source/daemon/agent/store.d`;
  `source/daemon/coord/access.d`;
  `source/daemon/coord/room.d`;
  `source/daemon/events/event.d`;
  `source/daemon/events/schedule.d`.
- The Command Center's custom Events and Schedules pages send `getState`
  messages without rendering replies; Policy rules are static markup and its
  Verify button is an alert. Settings has real bridge read/write actions.
  These are different levels of UI-to-daemon integration in assets presented
  as one surface.
  Evidence: `assets/pages/events.html:296-312`;
  `assets/pages/schedules.html:296-312`;
  `assets/pages/policy.html:221-322`;
  `assets/pages/settings.html:394-507`;
  `source/launcher/bridge.ts`.
- `install.sh` is a 396-line Bash entrypoint whose installer logic is a
  Python heredoc beginning on line 22; Bash handles pre-build/build gates and
  then invokes Python for argument parsing, filesystem checks, staging,
  installation, and rollback. This records the actual language split without
  resolving the requested entrypoint name.
  Evidence: `install.sh:1-396`.
- `source/daemon/interop/devin/stub.py` remains tracked. Its entire body
  redirects a Desktop-spawned shim at two developer-specific absolute paths.
  A repository-wide reference search found no in-tree caller of that path; the
  stated caller is a stale, cached Desktop registry outside the source tree.
  Whether that external reference is still in use was not tested or modified.
  Evidence: `source/daemon/interop/devin/stub.py:1-8`; the tracked-file search.

## Guidance and observed conventions

The local guidance contains test, runtime, route, UI, and security claims but
does not accurately describe the audited tree in every case. It documents an
`eval` configuration and live eval source although `dub.json` defines only
`daemon`, `unit`, and `relay` and `source/evals/` is absent. It cites
`source/launcher/tests/integration/desktop.mjs`, which is absent from the
tracked tree; launcher tests present at this revision are in `tests/unit/`.
CI invokes the eval build despite that configuration mismatch. It also
describes version-2 execution records although the current writer emits
version 3. The guide's description of the external installer entry remains
`install.sh`, which currently mixes a Bash build gate with a Python installer
body. These are specific differences at this revision, rather than a general
assessment of whether the guide is useful.
Evidence: `AGENTS.md:1-12,20,32-38,83-104`;
`dub.json:1-70`; `.github/workflows/ci.yml`;
`install.sh:1-396`;
`source/daemon/interop/execution.d:165-181`;
`source/tests/session.d:283-314`; `git ls-files source/launcher/tests`.

The IDE metadata supplied with the request names `research/architecture.md` as
an open document, but that path was absent on disk and not tracked at this
revision. No file at that path was overwritten. The review and module maps
are being written as new, explicitly allowed `research/` documents.

The style findings in this historical review were superseded by the current
code-style guide, which uses `intuit`, `selenium`, `akashi`, and `multidasm` as
the authoritative references.

## Questions the evidence leaves open

- What does “sessions listable by the bridge” mean: backend CLI inventory,
  sessions Autonom has admitted, relay-observed sessions, or a particular
  view of those sets? The CLI-listing method has no checked-in caller; both
  current HTTP views use the managed-plus-observed bridge ID set.
- Which externally created Desktop sessions, if any, must remain addressable
  for metadata, prompts, cancellation, tool injection, and profile/coordination
  identity? Those operations currently cross the bridge, ACP client, relay,
  observation registry, control socket, and capabilities.
- Which execution properties must survive daemon restart, and what is their
  authoritative source? The CLI database describes sessions and transcripts;
  `Execution` records describe daemon-started work and process outcomes.
- What exact permission fields must be shown to the human, which party is
  allowed to decide, how long may the hook wait, and what happens across daemon
  restart? The current answers are encoded in the HTTP/hook exchange, not in
  `Session`.
- Does the product require the relay to observe/rewrite host ACP sessions and
  inject prompts, or only the managed subprocess protocol? The relay is an
  executable and the observation/control features are exercised by tests.
- Which state is identity, which is authorization, and which is coordination
  ownership? The same session ID appears in CLI metadata, bridge handles,
  Access, capability grants, profile assignments, and observed connections.
- Which local guide statements are normative and current? Some configuration
  and test paths cited by `AGENTS.md` are absent from this revision.
- Which parts of the Command Center pages are intended to be live daemon
  views? The current event/schedule/policy assets do not all consume bridge
  responses.
