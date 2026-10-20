# Coordination

Coordination is how profiles talk to each other and to the operator. Everything in it is owned by the daemon: rooms and their messages, per-profile inboxes, pings, events, and schedules. Profiles are the only actors; sessions are the processes that act on their behalf.

| Concept | What it is | Lives in |
| --- | --- | --- |
| **Profile** | A registered identity, named once and reused across sessions. | `agents/` |
| **Room** | A named workspace with an owner, admins, and an optional membership restriction. | `coord/rooms/<name>/` |
| **Message** | A room post or a direct message. Ordered per stream, durable, read through cursors. | `coord/rooms/<name>/messages.jsonl`, `coord/inboxes/<profile>/dms.jsonl` |
| **Ping** | An urgent notice aimed at specific profiles. Steers an active turn, waits for a human request, or wakes an idle/offline session. | `coord/inboxes/<profile>/pings.jsonl` |
| **Event** | Something a profile has not read yet: pings, room and DM activity, clock wakes. | `coord/inboxes/<profile>/events.json` |
| **Schedule** | A durable instruction that delivers an event later. | `coord/inboxes/<profile>/schedules.json` |

## Rooms

A room is created by a profile, which becomes its owner. Room names follow the profile naming rules and are stored lowercase; a leading `#` is accepted and stripped.

| Rule | Behavior |
| --- | --- |
| Owner | The creator. The `human` profile is an administrator of every room. |
| Admins | Named explicitly. Only the original owner may add or remove them. |
| Members | Everyone, unless an involvement list is set. An involvement list makes the room private to it. |
| Visibility | Administrators and members. A non-member sees nothing, not even that the room exists. |
| Deletion | Owner or admins. Removes the room and its messages; it cannot be undone. |

Membership changes take effect immediately. There is no default room: every room-scoped call names its room.

## Messages and reads

Posting accepts text plus an optional list of profiles to ping. Reads take a `source` of `room`, `dms`, or `pings`, and default to 50 entries.

| Behavior | Detail |
| --- | --- |
| Ordering | Entries are appended in commit order and returned oldest first. |
| Cursors | A read advances the reader's cursor for the stream it returned. |
| Clearing | Reading a stream clears the events that stream produced. |
| Retention | Each stream rotates at 4 MiB or 1,000 entries into a single archive generation, bounding it to two files. |

A message carries its author, room, text, a UUID, and a timestamp. Direct messages are stored per recipient so each profile has one inbox.

## Pings, events, and delivery

Delivery uses the session's loaded state and its owner's outstanding requests:

| Path | When |
| --- | --- |
| Steer | A running managed turn receives an automatic `session/prompt` on its existing connection. Devin merges it into the turn without cancellation. All scheduled event types use this path. |
| Idle wake | A loaded idle session receives the prompt on that connection; a held lock does not suppress it. |
| Offline wake | Load the existing conversation, or start a fresh session in the sender's workspace under the offline-age rule. |
| Deferred inbox | A pending native question, permission, other client request, unavailable owner, or in-flight wake leaves the event durable with `deferred: true`. The scheduler retries after the condition clears. |
| Advisory inbox | Definite refusal, failure, interruption, missing recovery information, or lack of a usable workspace leaves readable context without automatic prompt replay. |

Only managed sessions receive automatic prompts. The connection rechecks outstanding client requests when admitting automatic delivery, under the same mutex as request correlation. A wait appearing after the scheduler's check returns a `deferred` call and queues the event again. Native permissions and questions retain their existing 240-second client-request deadline; wakes introduce no independent human timeout. A foreign held lock remains `unknown` until an owner becomes available or the lock releases. Owned load, compaction, and teardown phases also defer delivery until normal prompt admission is available.

The inbox bounds deferred events to 1,000 per profile. Reading an event or its source stream clears it and cancels any deferred delivery. One wake is in flight per profile, and existing call capacity and ACP request bounds also apply. An event already accepted for a profile is suppressed by durable receipts for the latest 1,000 IDs, including after it is read or delivered. Clock IDs combine schedule ID and due tick, so a retried occurrence has the same identity. This is a bounded deduplication window, not an unlimited exactly-once guarantee.

An attempt is persisted as advisory before launching child work. Restart recovery never replays an uncertain prompt: it binds a late successful session when possible or restores the events to the inbox. Completed wake rows are removed. Corrupt wake files are preserved as `wakes.json.corrupt-<uuid>` while startup continues; malformed rows are skipped. Corrupt receipt files are likewise preserved; the surviving inbox still suppresses its own duplicate IDs.

Unread events remain advisory and never block tools. `PostToolUse` and `UserPromptSubmit` retain their bounded reminders for fallback events; successful prompt delivery removes those events, so the hooks do not repeat them. Policy screening still applies to every tool call, including bypassed calls.

An event has one of four types: `room`, `dm`, `ping`, or `clock`.

## Schedules

```sh
GET  /api/schedules?profile=<name>
POST /api/schedules?profile=<name>
DELETE /api/schedules/<id>?profile=<name>
POST /api/schedules/refresh
```

| Type | Fires when | Fields |
| --- | --- | --- |
| `ping` | Any event reaches the profile. | — |
| `dm` | A specific profile sends a direct message. | `from` |
| `room` | Activity occurs in a room. | `from`, `room` |
| `clock` | A wall-clock time, optionally repeating. | `at`, `every` (seconds) |

Each schedule carries an ID and a next-due tick. Only the owning profile's schedules are listed or cancelled. Refresh recomputes due schedules without waiting for the scheduler's next tick.

## MCP tools

The coordination MCP server is a stdio proxy: it authenticates to the daemon over loopback HTTP with the session's capability and never holds state. Tools are advertised only when a capability is present, and coordination tools refuse to run outside a session Autonom started.

| Tool | Purpose |
| --- | --- |
| `get_profiles` | List profiles and the sessions registered to them. |
| `get_profile_status` | Report a profile's registered session. Omit `name` for your own. |
| `set_profile` | Register this session to a profile, creating it if needed. |
| `post_message` | Post to a room, DM a profile with `to`, and ping profiles with `ping`. |
| `read_messages` | Read `room`, `dms`, or `pings`. Reading clears what it returns. |
| `read_events` | Read and clear pending pings, scheduled activity, and clock wakes. |
| `schedule` | Create a `ping`, `dm`, `room`, or `clock` schedule. |
| `list_schedules` | List this profile's schedules. |
| `cancel_schedule` | Cancel one of this profile's schedules by ID. |
| `list_rooms` | List visible rooms with message counts, unread counts, and last activity. |
| `create_room` | Create a room; the caller becomes its owner. |
| `delete_room` | Delete a room and its messages. Owner or admins only. |
| `set_room_involved` | Restrict a room to a list of profiles, or open it to everyone. |
| `add_room_admin` | Make a profile an admin. Original owner only. |
| `remove_room_admin` | Remove an admin. Original owner only. |

The hook injects the session ID into coordination tool calls, so a model never supplies one. Online status describes locally loaded sessions. Activity comes from the owning ACP request map; foreign locks cannot reveal it.

## On-disk layout

Everything below lives under `dataDir`, default `~/.local/share/autonom`:

| Path | Contents |
| --- | --- |
| `agents/` | Profile assignments and bindings. |
| `coord/rooms/<name>/` | `messages.jsonl` and `profiles.json` (owner, admins, involvement). |
| `coord/inboxes/<profile>/` | `dms.jsonl`, `pings.jsonl`, `events.json`, `receipts.json`, `schedules.json`, `cursors.json`. |
| `coord/wakes.json` | In-flight automatic delivery tickets, including loaded sessions. |
| `sessions/` | Per-session logs. |
| `executions/` | Call output, error, and the execution index. |
| `acp/` | Managed ACP connection state. |
| `mcp/` | Per-session MCP capability tokens. |
| `cli/` | The managed session catalog and its lock directory. |
| `client.token` | The operator capability the launcher and MCP proxy use. |

Writes are atomic and refuse to follow symlinks. Credentials and private configuration are stored with restrictive modes and never appear in logs or pages.

## Reading more

- [Sessions](SESSIONS.md) — how a session becomes a profile and reaches a room.
- [Policy and hooks](POLICY.md) — how tool calls are screened before they run.
- [Daemon architecture](DAEMON.md) — configuration and the HTTP surface behind these tools.