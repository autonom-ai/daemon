# Autonom Review and Simplification Plan

This document records the proposal at the research baseline below. The user
subsequently authorized implementation, HTTP permission waits until deadline,
and a source cutover with live Desktop compatibility explicitly unverified.
Installed configuration remains untouched. See [current daemon contracts](../docs/DAEMON.md)
and Linear ANM-36 for implementation status; the style guide is maintained
separately in [style-rules-revision.md](style-rules-revision.md).

## Status and clarified requirements

This is the architectural proposal following the audit and the user's answers
to the six clarification questions. Product requirements below are settled;
implementation choices and integration claims still require verification.
Approval of these requirements is not an instruction to start the refactor.

Confirmed requirements from the full request:

- Audit the whole repository, including every file/folder, not only ACP.
- Match the author's mature repositories in style, conventions, readability,
  modularity, and paradigm, especially Intuit and Selenium.
- Prefer minimal, intuitive, language-native ownership and direct behavior;
  reject unused features, speculative abstractions, and disconnected systems.
- Bridge owns CLI/execution behavior; database metadata is surfaced through
  `Session` objects listable by the bridge. List all sessions from the database
  by default, with ACP filtering to select Autonom sessions.
- Rethink relay/taps as direct, modifiable protocol frames, not another renamed
  abstraction stack. Devin Desktop/Autonom ACP interoperability is essential
  to the native UI, not an optional feature to cut.
- Restart must preserve backend sessions, everything in the data directory
  and configuration, and file-backed logs. A separate durable execution
  history or automatic replay of interrupted work is not a primary requirement.
- Permissions use the HTTP API and Devin Desktop's native permission system.
  Do not build a special approval UI.
- Profiles, coordination/rooms/DMs, events/schedules, policy, and the Command
  Center are all core features. Audit their implementations without treating
  those capabilities as optional.
- Use `install.py`, not a shell wrapper or a TypeScript installer port.
- Replace ineffective agent guidance; `style-rules-revision.md` supersedes
  the removed, outdated global rules and is the adopted style baseline.
- Do not retain legacy source such as `stub.py`.
- Produce an architectural review and exhaustive file/folder breakdown before
  broad implementation; preserve unrelated and concurrent user changes.

These answers replace the earlier draft's CLI-discovery assumption, proposed
custom approval controls, suggestion to omit core views, and hesitation about
the revised style rules. Existing behavior is evidence, not proof that its
implementation or its abstractions must remain.

Remaining integration gates are specific, not open-ended architecture
questions: establish the persisted ACP identity used by filtering; demonstrate
native Desktop permission/rendering compatibility; and verify session reload
and durable-state preservation across restart. ACP's ability to load a session
does not by itself prove reconnection to an in-flight process or prompt.
One narrow policy choice remains: whether API-only permission requests wait
for an HTTP decision or cancel immediately when Desktop is not attached.

## Scope and conclusion

This proposal follows the research; it is not another inventory or an
implementation. The source baseline is `08a8af4`; `111121c` adds the
nine research documents and their ignore exceptions without changing that
implementation. No production code, installed files, profiles, or external
style rules are changed by this review.

The central problem is fragmented ownership, not insufficient patterns:
session discovery, metadata, execution, permissions, and ACP traffic have
separate representations that do not form one dependable public API.
Formatting those representations or moving them into new folders will not fix
that. Nor should a replacement introduce a broker, service framework, generic
task engine, or speculative multi-backend hierarchy.

The target is a concrete bridge that controls the CLI and lists canonical
`Session` objects from a read-only database catalog that supplies their metadata,
and direct ACP frame handling that permits inspection and modification before
forwarding. Keep domain boundaries; remove alternate universes of the domain.

- [Daemon inventory](daemon-map.md) documents every daemon file and folder.
- [Repository inventory](repo-map.md) documents the rest of the source baseline.
- [Disposition](disposition.md) assigns every baseline file a keep/change/remove
  decision and records its cutover dependencies.
- [Adopted style guide](style-rules-revision.md) provides the reference evidence
  and current conventions. The earlier style comparison was removed after adoption.
- [Session investigation](sessions-acp.md) and [permission investigation](permissions.md)
  preserve current behavior separately from the proposed design here.

## Findings, ordered by impact

### 1. High: session listing is not the bridge's backend session catalog

`GET /api/sessions` enumerates `Bridge.sessionIds()`, which unions managed
membership with observed connections. The implemented `Devin.list()` invokes
the actual CLI but is not used by either public session listing. `findSession`
only resolves cached or observed handles. A persisted managed ID without a
restored execution/profile handle can consequently appear in the ID list but
not resolve as a session; the richer client state silently skips it.

This is both an integration defect and the wrong conceptual API. Admission
must not determine whether backend metadata exists.

Evidence: `interop/bridge.d:149-172,272-281`,
`interop/devin/bridge.d:35-43,359-383`, and `client.d:56-70`
under `source/daemon/`.

Decision: one bridge catalog returning `Session` objects, with consistent
lookup. Keep authorization distinct from discovery.

### 2. High: permission handling is disconnected from its native protocol

The hook path creates a UUID-keyed global `PermissionStore`, copies the full
tool input, and polls for up to 240 seconds. The ACP runner independently
handles `session/request_permission` by selecting `reject_once`, otherwise
returning `cancelled`. The checked-in launcher has no permission decision
action or page even though client state includes the global queue. The absence
of a custom approval page is not itself a missing product feature: the user
wants the HTTP API and native Desktop permissions, not another approval UI.

The record is not literally a second `Session` object: its session ID has a
real polling-authorization use. The design fault is that the request does not
belong to the existing session/protocol lifecycle, while the actual ACP
permission path never consults it.

Retention is also poorly integrated. Settled and expired entries can remain
until another add or hook poll; pending state includes complete copied input.
The 64-entry count cap does not make this a small byte budget. Large permission
inputs can make aggregate client state exceed the launcher's 6 MiB response
limit, independently of whether an approval control exists.

Evidence: `source/daemon/interop/permission.d:14-148`,
`source/daemon/interop/devin/acp.d:131-154`,
`source/daemon/hooks.d:246-263`, `source/daemon/client.d:28-35`,
`source/launcher/client.ts:10,198-209`, and [permissions.md](permissions.md).

Decision: session-associated pending protocol requests, native Desktop
decisions and an HTTP response path. Remove the detached permission subsystem,
not human consent or request correlation. Do not add launcher approval pages.

### 3. High: a lossy observation mechanism now carries required protocol state

The current tap discards oversized frames and its 64-item queue silently
declines additional observations. `RelayAgent.frame()` uses these observations
to correlate session creation/loading, activity, and issued MCP capabilities.
MCP injection is performed before forwarding the request, but admission
depends on observing its reply. Thus "observation" is not optional telemetry:
dropped traffic can leave a backend session with an injected but unbound
capability or stale live state.

Evidence: `source/daemon/interop/acp/frames.d:135-237`,
`source/daemon/relay/agent.d:466-622`, and
`source/daemon/interop/acp/relay.d`.

Decision: process complete frames once on the authoritative forwarding path.
Required state transitions must not travel through a best-effort tap.

### 4. High: the visible product surface claims more than it implements

Events and Schedules send `getState` without rendering the response. Events
announces an empty/healthy inbox and its acknowledgement button only alerts.
Policy displays hardcoded rules and a fake verification alert. Settings is
actually wired, but considers either of two independent save responses a
complete success; the first successful response can mask a partial failure.

Evidence: `assets/pages/events.html:223-312`,
`assets/pages/schedules.html:224-312`,
`assets/pages/policy.html:221-322`, and
`assets/pages/settings.html:426-494`.

Decision: complete the core live views and remove pretend actions. Loading,
error, and genuinely unavailable states must be honest, but hiding a page is
not completion of a required feature. Do not build an elaborate UI framework
around static demonstrations.

### 5. Medium: execution has become a second application model

`Execution` combines a task delegate, dependency sequencing, process monitoring,
steering, log aggregation, versioned persistence, copied launch metadata, and
its own HTTP identity. Bridge registries, session state, scheduler wakes,
capability grants, and client transcripts all depend on it. Completed records
are retained in registries; request refresh repeatedly scans their history.

Its TODO proposes replacing execution records with the CLI database, but that
database does not supply process cancellation, timeouts, prompt outcomes,
pre-session startup failures, or exit status. Deleting the class without
placing those responsibilities would simply move the bugs.

Evidence: `source/daemon/interop/execution.d:1-111,164-267,278-631`,
`source/daemon/interop/bridge.d:34-39,284-348`, and
`source/daemon/events/scheduler.d`.

Decision: retire the execution framework and duplicate metadata journal.
Keep the small amount of active-run/result state the bridge actually needs;
use explicit compact-then-resume control flow instead of a general task graph.
HTTP async responses need not be broken merely to remove their backing class.
File logs and all existing durable state must survive the transition.

### 6. Medium: the backend abstraction is mostly a one-implementation hierarchy

The runtime constructs `Devin`, but public behavior is split between abstract
`Bridge`/`Session`, `Devin`/`DevinSession`, backend ACP tasks, execution objects,
and separate route modules. Some wrappers only call back into the same bridge.
Models also import runtime globals and HTTP helpers, obscuring the boundary
between a usable domain handle and a Serverino endpoint.

Evidence: `source/daemon/runtime.d`, `source/daemon/interop/bridge.d`,
`source/daemon/interop/session.d`,
`source/daemon/interop/devin/session.d`, and `source/daemon/app.d`.

Decision: one concrete implementation now. A future second backend must earn
an interface from actual shared behavior, not inherit today's speculation.

### 7. Medium: installer and guidance hide rather than clarify the system

`install.sh` is a short Bash build gate around a large Python heredoc. Make it
`install.py`: ordinary Python functions, argument parsing, and direct
subprocess calls, not another shell wrapper or a new installer framework.

The staging, rollback, package ownership, generation checks, symlink refusal,
and original-CLI verification protect real requirements. They are not bloat.
Do not confuse removing a language wrapper with removing transactional safety.

`AGENTS.md` contains stale eval commands, an absent integration script, outdated
record-version claims, and obsolete MCP/session-injection wording alongside
real safety constraints. CI still builds an undeclared `eval` configuration.
Its volume and drift make it an unreliable instruction surface.

Evidence: `install.sh:1-22,72-154,237-396`, `AGENTS.md`,
`.github/workflows/ci.yml`, `dub.json`, and [verification.md](verification.md).

Decision: direct Python installer; replace, rather than append to, the agent
guide with short verified instructions. Keep detailed contracts beside the
responsible implementation/tests and the Desktop validation documents.

## What the reference repositories actually teach

| Reference | Observed pattern | Application here |
| --- | --- | --- |
| `Libraries/selenium/source/selenium/bridge.d` and `driver/package.d` | Concrete server/process owner; handles identify its sessions and expose useful behavior. | Bridge owns CLI resources; `Session` is a real domain handle, not an abstract forwarding ladder. |
| `Libraries/intuit/source/intuit/router/package.d`, `router/openrouter.d`, and `context/package.d` | Interfaces describe genuine provider/router capabilities; state remains with the context/router; direct typed operations and UFCS. | Keep the existing Intuit boundary for policy. Do not imitate the interface count where Autonom has only one implementation. |
| `Insurgent/client/source/gui/game.d` | Direct domain composition, explicit callbacks and lifetimes, consuming Selenium's real handles. | Keep lifecycle and resource ownership visible instead of adding an orchestration service. |
| `Apps/devin-better-acp/source/antigravity/protocol.py` and `translate.py` | Bounded newline JSON-RPC frames, ordinary decoded messages, explicit method handling and correlation. | Adopt the frame/protocol idiom, not the unrelated provider translation or its full subsystem layout. |
| `Apps/chemica/app/src/chemica/` and `Apps/autohandshake/` | Language-specific domain/source modules rather than one universal layout. | Python remains idiomatic Python; do not impose D naming/access-section rules on it. These are secondary references, not authorities over the D libraries. |

The checked-out Insurgent API does not contain a usable D implementation to
compare; its JavaScript assets are not evidence for D style. Likewise the
Better ACP guide says its TypeScript follows Autonom, so that statement is
not independent proof that Autonom's architecture is good.

The adopted style revision is useful precisely because it distinguishes D visibility,
`scope` guards, references, accessors, and attributes semantically. Accessors
are not all `ref` returns: returning `ref` exposes mutable storage and can
bypass an invariant. Getter/setter visibility and cleanup are separate issues.
Do not convert these distinctions into another cargo-cult checklist.

For implementation, establish the concise project guidance before the
structural edits: four-space Allman D/TypeScript, meaningful names, `ret` for
constructed returns, project/dependency/runtime import grouping, intentional
access sections, field-like accessor use, and language-native Python.
Use the adopted revision's contextual inference, accessor, naming, and layout
guidance instead of resurrecting the removed blanket bans. `@property`, `ref`,
`auto`, and visibility each have actual language semantics; choose them for
that reason, not mechanically. No external configuration is edited here.

The largest readability defect is tracing ownership across modules, not a
missing brace. Fix that first; fix unjustified local imports, unreadably long
lines, `ret2`, gratuitous wrappers, and inconsistent page scripts while touching
their owners, using the revised rules rather than the old absolutes.
No wholesale sibling-repository formatting sweep is needed.

## Target ownership

| State or operation | One authority | What must not duplicate it |
| --- | --- | --- |
| Backend session existence and discovery | Read-only database catalog exposed by Bridge, all sessions by default with optional ACP/Autonom filtering | CLI subprocess listings, managed membership, profiles, observed connections, and execution history are not alternate catalogs. |
| Session identity and public behavior | One canonical `Session` per backend ID | No `Session`/`DevinSession` forwarding pair or manufactured session IDs. |
| Title, model, mode, workspace, timestamps, history | Read-only CLI database adapter, surfaced through `Session` | No durable Autonom copy that competes with the backend row. |
| Owned child, timeout, cancellation, active prompt and result | Bridge's live operation/connection state | Database timestamps are not running signals; no independent durable task framework. |
| ACP framing and response correlation | The connection that owns that stream | No second parser, tap queue, header scanner, or injection facade for the same traffic. |
| Pending human decision | Session-associated request on its owning connection, answered through native Desktop or the HTTP API | No global permission store or custom approval interface with another session lookup/lifetime. |
| Authentication and admission | Scoped capabilities bound to canonical session/run/connection | Listing a session does not authorize it; don't forward operator authority to children. |
| Profile assignment | Profile store's durable assignment snapshot | Not backend metadata, an ACP transport field, or an access catalog. |
| Messages, unread events, schedules, wake intent | Existing coordination/event owners | Similar JSON or shared IDs do not make these the same state. |
| Desktop capture/restoration and custom pages | Existing launcher/native runtime owners | No daemon UI framework or new launcher orchestrator. |

### Bridge and Session behavior

`Bridge.list()` should return `Session[]` from the database, not an
admission-filtered string array or the output of a listing subprocess.
The default is all backend sessions. ACP identity is an explicit filter so
callers can request only Autonom sessions without changing that default.
Resolve each discovered ID through the same canonical-handle lookup used by
detail endpoints and profiles. Include newly created live sessions while the
database row catches up; do not expose every stale cached handle forever.

The current adapter reads `backend_type`, but neither that query nor the test
fixture establishes the persisted Autonom ACP discriminator. Verify the pinned
backend's actual database schema and connector identity before choosing the
filter column/value. Do not equate "ACP" or a generic CLI backend with
"Autonom", infer provenance from a title, or use active capability membership
as a substitute. The filter must continue working after restart. Use the
backend's supported persisted identity; do not write ad hoc columns to its
database or create a second catalog to avoid investigating this seam.

Fetch metadata in a bounded batch for a listing instead of opening SQLite for
each accessor. A refreshed `Session` view supplies field-like metadata and
explicit control actions. Missing metadata during creation is normal; an
unreadable/corrupt database is a distinct error, not quietly "no sessions".
Only provisional launch values fill the pre-row gap. An existing backend row
wins over launch metadata.

Remove the unused CLI-listing path and its process overhead once all callers
use this catalog. Do not keep it as an undocumented fallback that disagrees
with database results.

A foreign held lock means loaded elsewhere, not actively generating. It must
not become controllable because it is visible. Operator authorization, live
connection ownership, and profile assignment remain explicit separate facts.

### The minimum execution state that remains

Keep owned process/connection references, a deadline, cancellation, a terminal
outcome, bounded diagnostic/result output, and a session association once the
CLI supplies an ID. New-session startup can fail before any backend ID exists:
use a small bridge-owned pending-call ticket, not a fake `Session` ID.

That ticket is not justification for `operation.d`, a generic executor, a
dependency graph, or a new journal of every metadata field. Scope it to actual
asynchronous API callers, consume/expire settled results under an explicit
bounded policy, and expose the current/last outcome through the session when
one exists. Do not confuse process exit zero with a successful ACP turn.

Keep logs written to files as the diagnostic authority; they survive restart
and are not reconstructed from memory or a metadata journal. Preserve existing
log paths/content through migration. Transient connection, process, and pending
request state does not need to become another persisted subsystem.

Preserve the existing data directory and configuration, including profile
assignments, coordination streams/cursors/events, schedules, and wake state.
Simplifying a class is not permission to discard its durable consumers.
Retain the wake intent needed for restart safety in the existing wake
store: target/profile, triggering event IDs, and progress sufficient to avoid
blindly replaying a prompt. Restart cannot prove success from a timestamp.
Uncertain in-flight work must reconcile as interrupted, not silently replay.
There is no new requirement to recover completed execution objects after
restart. Preserve sessions and logs, not fictitious live process handles.
Session loading/reconnection and any surviving in-flight work require actual
ACP/backend validation; do not assume the protocol restores them automatically.

## ACP: frames, not a framework

ACP already supplies the packet boundary: one newline-delimited JSON-RPC
message. Do not invent a binary envelope, packet inheritance hierarchy,
middleware chain, plugin registry, or second session protocol.

Use an ordinary frame value containing the decoded JSON envelope. The frame
reader owns complete input, enforces the byte limit, and distinguishes
request, notification, result, and error. The forwarding code can modify
`params`, `result`, IDs, or extension fields directly before serializing the
frame. Read one representation, modify that representation, write it.

```text
read complete frame
  -> validate envelope
  -> handle the few methods Autonom owns
  -> bind session/capability state if the result creates or loads a session
  -> forward or respond
```

This intentionally preserves ACP semantics and unknown JSON members, not
arbitrary-byte `/bin/cat` behavior, original whitespace, or JSON key order.
Those are different contracts. Replace the byte-proxy tests with real frame
round-trip tests; do not retain raw/parsed/shadow/header copies just to keep a
test for a feature the product does not need.

There are only two useful implementation responsibilities:

- Frame: bounded newline decoding, envelope validation, JSON value access,
  and encoding. String and numeric IDs remain distinct.
- Connection: the real stream/child lifetime, serialized writes, pending RPC
  correlation, cancellation, and explicit method handling.

A small protocol module is warranted only if concrete ACP method handling
outgrows the connection. Do not create a file/type per trivial message or a
schema system for fields Autonom simply passes through.

### Forwarding and control rules

1. Handle each required transition before forwarding the corresponding frame.
   Session admission must not wait for a lossy observer. Bind issued MCP
   capability to the returned session before delivering a successful
   creation/load result; a failed call leaves no usable provisional grant.
2. Use one correlation mechanism per connection. If both Desktop and the
   daemon originate requests on the same backend stream, allocate wire IDs
   and map them to the original peer/ID. Do not assume a magic string prefix
   can never collide with a client ID. Route replies once and restore IDs.
3. Keep native backend-to-client requests and notifications working.
   Permissions, file/terminal requests, errors, unknown extension members, and
   cancellation are not all prompt text. Advertise only capabilities the
   selected client actually supports.
4. The reader must keep processing while a human decision is pending.
   Dispatch a request and later send its response; do not block the sole
   protocol reader in a synchronous permission callback.
5. Bound frames and outstanding requests. Apply backpressure or report an
   explicit failure at capacity; never silently drop authoritative messages.
   Invalid/oversized frames terminate the affected connection cleanly, without
   an unbounded discard buffer or corrupted continuation.
6. EOF, child failure, timeout, and cancellation release pending requests,
   capabilities, and owned resources once. Keep stderr separate from protocol
   stdout, reap owned children, and preserve environment scrubbing.

The exact frame cap must be tested against the installed peer before cutover.
Use one documented frame budget across the ACP path, not today's unrelated
tap/header/consume caps. Test the boundary and a representative large valid
`session/load`; do not lower a limit simply to make a parser easier to write.

### What happens to the relay executable

Desktop compatibility is an acceptance requirement for this replacement:
session creation/loading, configuration/model/mode selection, message/tool
updates, native permission rendering and responses, cancellation, and
reconnection must behave correctly through Autonom ACP. Match the Devin Local
ACP contracts that Desktop actually consumes; do not assume compatible
framing alone makes the native UI work. Do not invent sessions, model values,
or approval controls to make a visual test pass.

Remove `RelayObserver`, `RelayInjection`, `FrameTap`, `FrameQueue`, partial JSON
header scanning, and the separate rewrite/observe/consume algorithms.
Replace the implementation, not merely its names.

A Desktop connector still needs a stdio executable, and controlling a child
owned by another process still requires communication across that real
boundary. Keeping `autonom-acp` as a small entrypoint using the shared
frame/connection code is not the same as keeping `daemon/relay/`.

Preserve the current process topology initially. Do not reparent every
Desktop child into the daemon or add a new IPC broker just to remove a
directory. Where the existing authenticated control socket is required,
make it a thin transport for the same frame operations. Keep only connection
and request-routing facts there, not another session/metadata registry.
Liveness should follow the actual control connection; remove heartbeat and
HTTP observation machinery only after that connection supplies disconnect
and revocation reliably. Do not delete required cross-process communication
and call the resulting loss of Desktop control a simplification.

## Permissions: native ACP and the HTTP API, not a new interface

Keep pending requests associated with the canonical `Session`, backed by its
connection's outstanding-request state. A request needs its original
correlation identity, offered options, approval context, and deadline.
It does not need a second session identity store, a random UUID for an
already identified ACP request, copied database metadata, a persisted history,
or computed reason strings stored as state.

Native Desktop owns its permission presentation. Forward the request/options
and route its selected response back through the same connection. Do not
automatically choose `reject_once` for every request, replace native option
semantics with a generic string, or create a second launcher approval panel.
Keep errors, tool context, permission modes, and extension metadata needed for
the native Devin Local-like presentation intact.

The HTTP API exposes that same session-associated pending state and accepts
authorized decisions; it does not maintain another queue or approval history.
Keep the current useful HTTP contract where possible while replacing its
backing ownership. Native and HTTP responses must settle a request at most
once; late or conflicting responses must not reach another request.

Own the decoded frame once rather than copying input through a JSON round
trip. Full approval context is available on demand under a byte limit, not
duplicated into every aggregate state response. Do not let truncation turn
an incomplete description into approval of unseen arguments.

Only offered ACP options may be selected, or the protocol's cancellation
outcome returned. Check operator authority and session/connection association;
a model knowing a request ID cannot approve itself. Remove settled requests
on delivery. Timeout, session stop, disconnect, and restart invalidate pending
requests without implicit approval. Use monotonic time for live deadlines.

For API-only sessions with no attached Desktop client, the proposed behavior
is to expose the pending request for an explicit HTTP decision and cancel at
the deadline. Confirm that waiting policy before implementing it; immediate
cancellation is the other simple option. Neither requires a special UI,
automatic approval, or a persisted request store.

`PreToolUse` policy is a separate enforcement requirement: automatic/bypass
tool calls may never generate a human-permission request. Keep that hook.
Do not move policy screening onto ACP approval prompts.

ACP supplies the native permission exchange. Before retiring the
`PermissionRequest` hook/polling path, trace the pinned CLI's event ordering
and prove ACP covers the same supported calls. If a current, required hook
flow is not represented by ACP, its minimal adapter must address the same
session-owned pending state; that is an actual protocol boundary, not a
reason to keep `PermissionStore`. There must not be two approval decisions
for one tool invocation. Do not correlate requests by tool name alone or
invent a universal approval bus to avoid validating the actual CLI behavior.

## Installer and agent guidance

### `install.py`

Extract the existing Python into the root `install.py` with a normal
`main()` and the same flags. Use `subprocess.run([...], check=True)` for
normal-user DUB/npm builds and existing verification commands; use Python
filesystem operations for the transaction. Remove `install.sh` and update
all tests, documentation, and printed recovery commands in the same change.
Do not leave a shell compatibility launcher.

Keep the canonical TypeScript build/package verifier used by the launcher.
Python calling its small CLI is a genuine language boundary; duplicating its
RPM/build-identity implementation in Python would be worse. The pointless
layer is Bash pretending to own a Python installer, not every process call.
Likewise the installed `exec node ... "$@"` shim performs a real OS-entrypoint
job and must preserve arguments, working directory, output, and exit status.

Preserve byte-exact vendor backup, package-generation ownership, symlink and
external-edit refusal, staged payload writes, fault rollback, and private
record handling. Building must still happen without elevation; installation
into a protected directory is a separately authorized action. No installer
or live installation command is run during this audit.

### Replace `AGENTS.md`, do not grow it

Use a short entry guide containing:

- Exact working build/typecheck/test commands and required tool versions.
- A small source-owner map, not every route and record field.
- Non-negotiable invariants: one mutable-state worker, owned IDs/buffers,
  scoped credentials, nonblocking child work, read-only backend DB access,
  and safe cancellation.
- The concise project conventions derived from the style research and the
  adopted `style-rules-revision.md`, with no contradictory old checklists.
- Links to the real Desktop contract/validation procedure and current
  architecture documentation.

Remove the nonexistent eval/integration commands rather than inventing
programs to satisfy stale instructions. Keep Desktop integrity and
observation-only live validation explicit. Detailed wire formats belong in
their implementation and contract tests, not in an ever-growing instruction
file that becomes a competing source of truth.

## Retain the useful product

Profiles/assignments, room membership and streams, independent cursors,
pending events, schedules, wake recovery, policy evaluation, scoped MCP
access, and the native Desktop adapter are confirmed core functionality.
Keep them and audit their implementations for duplication, style, and
integration. They have distinct lifetimes. Stream history is not unread-event
state; profile assignment is not session metadata; authorization is not discovery.

Keep small package exports when they make a real D package convenient.
Keep the fake agent and synthetic native-service fixtures as clearly labeled
unit-test seams. They are not legacy production shims and are not evidence
of live backend/Desktop behavior.

The launcher needs local simplification, not an architectural replacement:
finite bridge actions, actual page data, native service types confined to
the capture seam, coherent page/settings ownership, and exact restoration.
Preserve the lease, invalid-reload rollback, private control socket,
HTML/JS configuration, and native imports. Share repeated page CSS and
request handling only where the pages actually use them.

`stub.py` has no place in the final source. Update the external Desktop
registration through an explicit deployment step, then remove the hardcoded
shim; do not silently edit a cached registry or retain the file forever.
Remove the empty static MCP configuration artifact when its installation
and guidance are removed. Dynamic per-session capability injection is the
actual implementation.

## Sequenced implementation

Each phase is a coherent behavior change with its own verification, not a
parallel file-renaming campaign.

| Phase | Change | Acceptance condition |
| --- | --- | --- |
| 0. Establish the contract | Replace stale agent/CI guidance using the adopted style revision and the clarified core requirements. | All documented commands exist; no old style bans, new eval framework, or stale current-test claims. |
| 1. Remove literal indirection | Extract `install.py`; update its tests and callers; identify the installed stub pointer for the deployment cutover. | Existing installer refusal/rollback/argv tests pass against temporary copies; no real installation/profile writes. |
| 2. Restore the domain API | Concrete Bridge/Session; database enumeration and batched metadata; all sessions by default and persisted ACP/Autonom filtering; canonical profile references. | Listings/details/filtering remain consistent after restart without profile/admission membership; foreign locks stay safe; metadata errors are visible. |
| 3. Replace ACP as a vertical slice | Shared frame codec and connection; new/load, MCP admission, notifications, requests, cancellation, and external control use that path. | No required state depends on taps; frame routing and actual Desktop/Devin Local-compatible native behavior pass before old relay code is deleted. |
| 4. Integrate permissions | Session-associated requests, native Desktop decisions, HTTP API; prove hook/ACP coverage then remove duplicate queue/polling. | Native permission rendering and HTTP decisions work; exactly-once approve/deny/cancel/expiry and ownership checks hold without a special approval UI or blocked reader/worker. |
| 5. Retire the execution universe | Migrate client/scheduler/profile/auth callers to bridge outcomes; explicit compact/resume; preserve durable wake state, all data/config, and file logs. | Sessions reload after restart; uncertain work is not replayed; async errors, cancellation, and failed deletion remain observable without a duplicate metadata journal. |
| 6. Complete the core surface | Wire Events/Schedules/Policy; await both settings writes; audit other core domains and trim duplicate presentation code. | All core functionality remains available, actual responses drive display, and live UI acceptance is separate from unit evidence. |
| 7. Delete and finish | Remove old relay modules, forwarding subclasses, stale schemas/loaders/templates, deployment stub, and dead callers; update exports/build/install. | No legacy compatibility wrappers or abandoned entrypoints remain; all in-tree consumers use the new contract and the inventory matches the source. |

Do not remove valuable behavior merely to satisfy a source-line target.
Conversely, tests for an obsolete implementation detail are not a reason to
retain the implementation: preserve the domain invariant and rewrite its test.

### Data and API cutover

The new design does not require a separate durable execution-history model
and changes session listings from admission IDs to database-backed `Session`
views with ACP filtering. Update all in-tree HTTP, launcher, scheduler, and
MCP callers in the corresponding
phase. Removing an implementation class does not require gratuitous endpoint
changes. Retain useful HTTP behavior directly; identify actual consumers
before removing obsolete endpoints. No permanent legacy compatibility layer
is proposed.

The data directory/configuration and existing logs must be preserved, not
reinitialized to fit the new architecture. Profile legacy import and execution
record versions are real existing data, not just source files. If migration
is needed, make it an explicit, bounded, one-time cutover, verify its result,
and remove the runtime compatibility
loaders. Preserve the original data unless the user specifically authorizes
its removal. Never convert an old "running" record into proof of a live
process, replay uncertain wakes, or write to the CLI's database.

Removing `managed.json` or a `trusted` flag is justified only after its
remaining authorization consumers are replaced; neither belongs in the
catalog, but that does not make deleting admission checks safe.

## Verification and limits

The latest existing raw evidence was inspected, not rerun or manufactured:

| Command at implementation `08a8af4` | Recorded result |
| --- | --- |
| `npm --prefix source/launcher run check` | Exit 0 |
| `npm --prefix source/launcher test` | 79 passed |
| `python3 source/mcp/tests.py` | 9 passed |
| `dub build --compiler=ldc2 --config=daemon --skip-registry=all` | Exit 0 |
| `dub run --compiler=ldc2 --config=unit --build=unittest --skip-registry=all` | 97 passed |

Raw output is under `/tmp/autonom-verification-20261016T201846Z-136803/`;
conditions are recorded in [verification.md](verification.md). The older
`0c4e09e` Python import failure is fixed, not a current finding.
No live Desktop acceptance, paid-model run, registry edit, installation, or
network access was performed for this plan.

Add regression coverage for the gaps, not just the new type names:

- Database catalog/detail consistency after restart, default all-session
  listings, correct persisted ACP/Autonom filtering, unassigned backend sessions,
  unavailable/corrupt DB, provisional creation, backend deletion, and foreign
  locks. Metadata updates must not need a new canonical handle.
- Split/coalesced frames, valid escaping/Unicode, numeric versus string IDs,
  simultaneous client/daemon requests, unknown methods/extensions, invalid
  envelopes, boundary/oversize input, capacity, and disconnect mid-request.
- Capability binding before forwarded session creation, failure/revocation,
  injected MCP configuration preserving unrelated servers, and no dropped
  admission when traffic exceeds the old observation queue.
- One pending decision, stable input ownership, only offered option selection,
  cross-session/role denial, repeated decisions, timeout, cancellation, and
  reader progress while a human waits. Native Desktop must render and complete
  the actual ACP request; HTTP and native decisions must not double-settle it.
- Startup before session ID, failed ACP turn with successful process exit,
  bounded diagnostics, stop/reap, failed removal, compact-before-resume, and
  uncertain wake recovery without duplicate prompts. Restart must preserve
  sessions, all configured data/configuration, logs, and ACP filter identity.
- Installer byte-exact restoration and all existing fault/refusal cases;
  partial settings-save failure and real page replies.

Fake CLI tests establish protocol/daemon contracts, not installed backend
compatibility. Native-service unit fixtures establish runtime logic, not a
rendered Desktop. Any later live acceptance must follow
`docs/COMMAND_CENTER_VALIDATION.md` against a separate exact target, with
observations/screenshots and pristine vendor bundles. Never synthesize the
surface or touch the communication window to obtain a green result.
