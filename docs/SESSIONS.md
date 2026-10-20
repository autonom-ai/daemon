# Sessions

A session is one Devin CLI conversation with a durable identity: a canonical ID, a workspace, a model, and a transcript. A live ACP process can keep it loaded between turns. Autonom supervises sessions; the model, tools, and transcript belong to the Devin CLI.

Two kinds exist, and the difference decides what Autonom may do with them:

| Kind | Catalog | Control |
| --- | --- | --- |
| **Managed** | `<dataDir>/cli/sessions.db` | Autonom started it, holds its ACP connection, and can steer, stop, and resume it. |
| **Native** | `~/.local/share/devin/cli/sessions.db` | Autonom only reads it. Discovery never grants control, and a foreign session lock means "loaded elsewhere", not "running". |

## Catalogs

Autonom children run the CLI with `CHISEL_SESSION_DB=<dataDir>/cli/sessions.db` and locks in `<dataDir>/cli/session_locks`, so managed sessions never share rows with native Devin state. Both databases are opened read-only.

`sessionDatabase` and `sessionLockDir` in the daemon configuration point at the *native* catalog; the managed catalog is always `<dataDir>/cli/sessions.db`. A held kernel lock selects a live catalog owner. With no holder, database membership selects the catalog, preferring the managed row for duplicate IDs. Stale lock files never select a catalog. An ID held in both catalogs is an explicit conflict. Listing, metadata, resume, removal, and transcripts use that ownership rule.

Existing tagged sessions are moved by a one-off offline migration. The daemon never moves or writes CLI rows.

## Discovery

```sh
GET /api/sessions?directory=<workspace>&acp=autonom
```

Results merge database rows with provisional live sessions. `directory` filters by workspace and `acp=autonom` filters to sessions whose persisted connector metadata names Autonom.

Sessions created before Autonom tagged them have unknown origin. They are listed, not claimed; adopting one is an explicit act. New and loaded sessions stamp `_meta["autonom/connector"]` so later runs can recognize them.

## Profiles

A profile is a name a session registers as through the `set_profile` MCP tool. The mapping from session ID to profile is durable and survives restarts; the profile itself outlives any single session.

| Rule | Behavior |
| --- | --- |
| Names | 1–64 characters, start with a letter or digit, then letters, digits, `_`, or `-`. Lowercased. |
| `human` | Reserved for the operator. It always exists and cannot be created. |
| Binding | One session is registered per profile at a time. Its durable assignment survives going offline. |
| Identity | A profile carries no prompt or model of its own. It owns an inbox, events, and schedules. |

Profile-to-session resolution is independent of discovery and admission: a profile keeps its assignment even while the session is offline.

## Lifecycle

Session responses expose two independent fields:

| Field | Value | Meaning |
| --- | --- | --- |
| `status` | `online` | A live process holds this session loaded, including between turns. "Attached" means this loaded lifetime. |
| | `offline` | No live process holds it. A stale lock file does not change this. |
| | `starting`, `stopping` | A daemon-owned call is attaching or being stopped. |
| `activity` | `idle` | No prompt or client request is outstanding on the owning connection, or the session is offline. |
| | `running` | A prompt response is outstanding. Silent tools remain running. |
| | `waiting` | A backend request awaits its client: native questions, permissions, or other client requests. |
| | `unknown` | Autonom cannot safely admit a prompt: a foreign holder, unavailable connector, or owned connection in setup, compaction, or teardown. |

The connection's request map supplies activity; observation heartbeats carry membership only. Desktop activity is read through its authenticated control socket with a 250 ms deadline. An unavailable control channel never grants permission to start a second process. There is no silence timeout and no inference from transcript text or lock-file contents.

A prompt response ends a turn; EOF ends the connection. `stopReason` is retained on its call and execution index: `end_turn` succeeds, `cancelled` stops, and `max_tokens`, `max_turn_requests`, `refusal`, unknown reasons, and RPC errors fail the call. Disconnecting before the response produces `interrupted`. A failed call does not make a loaded session offline, and loading an interrupted conversation does not replay its old turn.

| Operation | Route | Behavior |
| --- | --- | --- |
| Start | `POST /api/sessions` | Accepts `prompt` and `directory`, plus optional `model`, `mode`, `profile`, and `trusted`. Returns 202 with the started session. |
| Resume | `POST /api/sessions/<id>/resume` | Sends a new prompt to the idle owning connection, or loads the offline conversation in a new process. |
| Steer | `POST /api/sessions/<id>/steer` | Injects text into a running generation without cancelling it. |
| Stop | `POST /api/sessions/<id>/stop` | Cancels the current generation and settles pending permissions. |
| Remove | `POST /api/sessions/remove` | Deletes the session from the catalog that owns it. |

Starting a session for a profile that is already active is a conflict: the daemon refuses rather than queueing a second agent for one identity.

Child work is bounded. At most eight calls run concurrently, each with a 30-minute execution timeout. Settled call tickets are evicted after five minutes or when the registry exceeds 128 entries, oldest first; a running call is never evicted. Eviction persists metadata to `executions/index.json` (bounded to 10,000 entries) first, so historical IDs still resolve. Call tickets are not durable history.

An automatic event prompt has its own call ticket on the existing connection. Its result cannot replace the ticket controlling the original headless turn. Internally, `hasActiveCall()` names an owned call, while `activity` describes the actual ACP turn.

## Supervision

`autonom-acp` is the stdio entrypoint Devin Desktop launches. `AcpClient` owns one child process and one correlation map shared by native Desktop traffic and daemon-owned requests.

| Bound | Value |
| --- | --- |
| Frame size | 16 MiB. |
| Outstanding requests | 256. |
| Outstanding permission requests | 64, 16 MiB in aggregate, 240 seconds. |
| Failure mode | Child stderr stays separate from protocol stdout and is written to a per-session log. |

Routing between Desktop and the daemon rewrites the ID of a *copied* envelope, so the original identity survives for replies. Inherited `ACP_BACKEND` and related `ACP_*` variables are removed before the CLI starts, so the CLI uses its own Devin backend.

## Permissions

A pending permission belongs to the connection that raised it. Native Desktop controls and authorized HTTP decisions settle the same request exactly once.

```sh
GET  /api/sessions/<id>/permissions        # offered options; add ?id=<request-id> for full context
POST /api/sessions/<id>/permissions        # {"id": 72, "optionId": "allow_once"} or a null option to cancel
```

Only offered options are accepted; a repeated decision returns 409. Requests expire after 240 seconds and are invalidated when the connection drops. Sessions with no Desktop attached wait for an explicit HTTP decision until that deadline instead of failing.

The `PermissionRequest` hook returns an empty response. Approval stays with the native Desktop UI and this HTTP route — there is no second approval queue.

## Compaction

`/compact` runs on the loaded ACP connection before a resume prompt is sent. If compaction fails or is cancelled, the prompt is not delivered.

| Setting | Default | Effect |
| --- | --- | --- |
| `compactOnResume` | `false` | Compact whenever a session is resumed. |
| `offlineStartAfter` | 1 hour | How long a profile may be offline before a wake is considered stale. |
| `offlineCompactAfter` | 1 hour | How long a session may sit idle before its next resume compacts first. |

The former `compactionThresholds` setting was removed. Delete it from a configuration file before starting this revision.

## Transcripts

```sh
GET /api/sessions/<id>/transcript
GET /api/executions/<id>/transcript
```

Transcripts are read from the owning catalog. When the CLI database returns no messages for an execution, the daemon falls back to the execution logs (`executions/<id>.out`, `executions/<id>.err`) and the session log rather than reporting an empty conversation.

## Reading more

- [Coordination](COORDINATION.md) — how sessions reach rooms, profiles, and schedules.
- [Policy and hooks](POLICY.md) — how a tool call is checked before it runs.
- [Daemon architecture](DAEMON.md) — ownership, configuration, and the HTTP surface.