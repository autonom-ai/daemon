# PermissionRequest lifecycle and state ownership

This is a source-and-test trace at repository HEAD `08a8af4bb4321021c3f4ef4f167ea14d55c23dc1`.
It records the current protocol and state boundaries; it does not make a refactor or keep/remove
recommendation.

## Lifecycle

1. **Devin starts the hook process.** `templates/hooks.v1.json` registers `PermissionRequest` as a
   command hook with a 250-second Devin timeout, versus 20 seconds for the other listed hooks
   (`templates/hooks.v1.json:1-9`, especially line 4). The command starts
   `source/daemon/interop/devin/hook.py` with `--event PermissionRequest`.

2. **The Python wrapper receives and forwards the event.** It reads at most 16 MiB from stdin,
   expects a JSON object, checks that its `hook_event_name` matches the registered event, and
   treats `PermissionRequest` as sensitive (`hook.py:9-13, 108-149`). `forward` POSTs the
   event object to `/api/hooks/permission-request`; the HTTP helper disables proxies, sends to
   loopback, uses a 10-second per-call timeout, limits replies to 16 MiB, and forwards the
   `AUTONOM_RUN_TOKEN` plus session and, when present, the session's MCP token
   (`hook.py:36-83, 86-105`). When a permission ID comes back, it starts a monotonic 240-second
   deadline and GET-polls `/api/permissions/<id>` with the event's `session_id` every 0.5 seconds.
   The first truthy `decision` is returned to Devin with its reason; exhausting the local deadline
   returns a block with reason `"Permission request expired without a user decision"`
   (`hook.py:91-105`).

3. **The daemon authenticates and queues the request.** `acceptHook` checks POST, reads at most
   16 MiB, verifies the event name, and authenticates the session using the run capability or a
   session-bound MCP capability. Hook routes bypass the general authorization middleware, so
   this hook-specific check is the relevant authentication step
   (`source/daemon/hooks.d:29-59`; `source/daemon/server.d:77-81`). For this event, the
   handler takes `tool_name` and the `tool_input` object (an absent input becomes `{}`; a
   non-object is invalid). A missing tool name gets an empty hook response. Otherwise it adds a
   request to the runtime `PermissionStore` and returns only its generated ID
   (`hooks.d:68-76, 246-263`; `permission.d:61-75`).

4. **A client lists and decides.** `GET /api/permissions` returns the store's globally pending
   entries (`permission.d:14-21, 88-98`). The endpoint also exposes per-ID GET and POST. A client
   capability (`x-autonom-client`) is treated as human; otherwise the caller must be doing a GET
   and its `x-autonom-session` must equal the stored session. Thus a session capability can poll
   only its own request and cannot POST a decision; a client-capability holder can view or decide
   any pending request (`permission.d:23-56`). POST requires exactly one string field, `decision`,
   and only `"approve"` or `"block"` are accepted. A second decision or a decision after expiry
   conflicts (`permission.d:44-51, 126-134`).

   The daemon also puts `permissions.pending()` in `/api/client/state`
   (`source/daemon/client.d:22-35`). The launcher client sends its client capability in
   `x-autonom-client` for API requests and offers a `getState` path
   (`source/launcher/client.ts:61-90, 97-100`; `source/launcher/bridge.ts:111-113`). The exact
   `/api/permissions` collection route is not in the server's session-capability allowlist
   (which matches `/api/permissions/` with a trailing slash); it therefore requires the client
   capability (`source/daemon/server.d:92-108`). The per-ID route is in that allowlist but has
   the additional session equality check described above.

   **UI source boundary:** in the checked-in launcher/assets, I found the client-state field and
   the generic authenticated client request, but no caller of `/api/permissions` and no
   permission-specific page/action. The checked-in navigation lists schedules, events, policy,
   and settings (`assets/ui.yml:5-34`). Consequently, the daemon API and state shape establish
   how an authenticated UI client can list/decide, but the checked-in source does not establish
   which visible UI component, if any, currently consumes or posts these values. A native or
   otherwise external UI consumer is not ruled out by that source inspection.

5. **The polling hook receives the decision.** On a non-human per-ID GET, the handler serializes
   the permission and removes it after responding only when the stored `decision` string is
   nonempty (`permission.d:36-56`). The Python wrapper then returns the approval or block to Devin
   (`hook.py:98-105`). The event's `PermissionRequest` route itself does not evaluate workspace
   policy; policy screening is in the separate `PreToolUse` route (`hooks.d:208-244, 246-267`).

## Stored state, lifetime, and execution context

Each queued `Permission` contains:

| Stored value | Source/use |
| --- | --- |
| Random UUID `id` | Generated at construction; also the key in `PermissionStore.requests` and the ID returned to the polling hook (`permission.d:61-75, 104-120`; `hooks.d:260-266`). |
| `session` string | Copied with `.idup` from the event's `session_id`; later compared to the session header and returned in JSON (`permission.d:107-120, 136-146`). |
| `tool` string | Copied with `.idup` from `tool_name`; returned for display (`permission.d:107-120, 136-146`). |
| `input` JSON object | The complete `tool_input` object, or `{}` if omitted. The constructor round-trips it through JSON serialization/parsing, retaining an independent copy (`hooks.d:68-76`; `permission.d:111-120`). |
| `createdAt` Unix timestamp | UTC time in whole seconds, used to calculate the 240-second expiration (`permission.d:110, 114-124`). |
| `decision` string | Initially empty; set once to `"approve"` or `"block"` (`permission.d:112, 126-134`). |

The original hook payload is not retained as a whole: the queue receives only session, tool, and
input. In particular, the shown constructor does not retain `hook_event_name`, `cwd`, `prompt_id`,
other event fields, or a separate reason (`hooks.d:246-267`; `permission.d:114-121`). `toJSON`
returns `id`, `session`, `tool`, `input`, `createdAt`, `decision`, and a computed `reason`; that
reason is `"User permission decision"` for a non-expired request even while its decision is
empty, and `"Permission request expired"` once expired (`permission.d:136-146`).

The store is a process-memory associative array, not a durable record. Runtime setup constructs a
new `PermissionStore`; the server configures one persistent Serverino worker and does not recycle
it on an ordinary lifetime or idle timeout (`source/daemon/runtime.d:13-36`;
`source/daemon/server.d:59-75`). No permission serialization or restart reload appears in these
paths. The daemon worker handles enqueue/list/decision/poll HTTP requests; it does not wait for a
human. The long wait is in the Python Devin hook process (`hook.py:91-105`). The independent test
for this behavior is named “waits outside the request worker”
(`source/mcp/tests.py:155-162`).

There are three separate retention/deletion behaviors:

* The 240-second store expiry is checked using UTC wall-clock Unix seconds. `pending()` omits
  expired or decided entries; `toJSON()` reports an expired entry as a synthetic block; and
  `decide()` rejects an expired entry (`permission.d:88-98, 123-145`).
* Expiry does **not** itself delete an entry. The only automatic sweep is in `add`, which removes
  expired entries before enforcing the 64-entry map cap (`permission.d:61-75`). Therefore an
  expired record can remain in memory, though not in the pending list, until another add sweeps
  it or the daemon process ends. An expired polling GET receives the synthetic block, but the
  post-response removal checks the stored `decision` field, which is still empty in this case;
  that GET alone does not remove it (`permission.d:44-56, 126-145`).
* A human decision also does not immediately remove the entry. It is omitted from pending
  results, but remains available for the hook's next GET; that GET removes it after the response
  because the stored decision is nonempty (`permission.d:44-56, 88-98`). If the hook never polls
  again, a decided entry remains until it expires and a later add sweeps it, or until daemon
  shutdown/restart.

The 64-entry cap counts all current map entries after the expired-entry sweep, not just entries
returned by `pending()`. Thus decided-but-uncollected entries count against the cap until removed
or expired and swept. Each incoming hook body is limited to 16 MiB by both the Python wrapper and
daemon hook reader (`hook.py:9-10, 123-125`; `hooks.d:29-34`). There is no separate per-field
or per-request input truncation in the queue path. As a loose wire-size bound, 64 nearly
16-MiB `tool_input` objects could retain close to 1 GiB of input JSON before accounting for
metadata; the parsed in-memory representation need not have the same size
(`permission.d:61-75, 114-120`). The launcher caps any daemon API response at 6 MiB, while
`/api/client/state` includes the pending inputs; a sufficiently large combined response therefore
exceeds that client-side display limit (`source/launcher/client.ts:10, 198-209`;
`source/daemon/client.d:28-35`).

## Session ownership overlap: what is and is not represented

There is already a canonical session model in the interop bridge: it holds `Session[string]
sessions` alongside executions and observed-session records; `findSession` returns the canonical
session handle, and `Session` owns a validated, copied ID plus access to its execution and backend
metadata (`source/daemon/interop/bridge.d:25-38, 150-172`;
`source/daemon/interop/session.d:193-230`). `Access` separately owns managed-session membership
and capability grants; its managed IDs are persisted, while execution grants are associated with
running executions (`source/daemon/interop/access.d:73-120, 123-139, 201-207, 242-250`).

The permission record does not contain a `Session` reference, session metadata, or a permission
collection attached to a session. It stores a copied session-ID string. There is nevertheless an
identity overlap: that string names the same session already represented by the bridge and
managed-session/capability state. It is also actively used by the current permission protocol:
the polled GET must match it, and the UI receives it as part of the record. Evidence therefore
supports describing this as a per-request session association with duplicated identity, not as a
second canonical session object or an existing session-owned permission registry. Whether that
association is considered protocol state or duplicate domain ownership is not settled by the
implementation alone.

For the current protocol, the permission UUID correlates enqueue with polling; the session
association scopes session-capability reads; the tool and input supply the approval context; the
timestamp supports expiry; and the decision carries the response back to Devin. The complete
input copy and the retention of settled/expired entries beyond the visible pending period are
also directly evidenced above. These observations distinguish protocol use from storage duration;
they do not establish how much input a human reviewer needs or how long the UI is expected to
retain a resolved item.

## Tests: what they establish and what remains uncovered

* `source/tests/daemon.d:183-259` checks hook event routes and payload validation, the 16-MiB
  reader limit, and that the registered PermissionRequest timeout is 250 seconds. Its
  integration scenario at `:299-319` starts a managed session, sends a PermissionRequest, GETs
  its returned ID with the test client's credentials, and posts `"approve"`; it proves this
  immediate queue/client-decision path, not session-capability polling or the complete Python
  polling loop.
* `source/tests/permission.d:8-22` checks pending → approve, rejection of a second decision,
  omission from pending after decision, session association, and explicit removal.
  `:24-33` checks that input remains independent when the original JSON value is mutated and
  that an unsupported decision leaves the decision empty.
* `source/mcp/tests.py:155-162` mocks three hook-call results (enqueue, no decision, approve),
  suppresses sleep, and checks that `forward` returns approval and leaves
  `server.SESSION_CONTEXT` empty. The test is named “waits outside the request worker,” but it
  does not exercise a real daemon worker or a 240-second wait.

In the inspected tests there is no asserted expiry boundary, automatic-sweep behavior, 64-entry
cap, block-decision path, cross-session denial, stale decided-entry cleanup, or checked-in
permission UI caller. Those behaviors above are source-derived rather than demonstrated by the
listed tests.
