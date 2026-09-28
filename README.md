# Autonom

## MCP server

The server is `autonom-coord-mcp` and runs from `source/coord/server.rb`:

```json
{
  "mcpServers": {
    "autonom-coord-mcp": {
      "command": "ruby",
      "args": ["<COORD_ROOT>/source/coord/server.rb"]
    }
  }
}
```

## MCP tools

Tool calls are designed to be as lean as possible. Session ID maps a session to a profile/agent,
and is used to identify the caller. After a session ID has been mapped, it cannot be changed and agents are disallowed from modifying the `sessions.json` map.

| Tool | Behavior |
| --- | --- |
| `get_profiles` | Lists existing profile names and directories. |
| `get_profile` | Returns the profile mapped to the current Devin session. |
| `set_profile` | Registers the current session once; creates a profile if needed. |
| `send_message` | Posts to a room (default: the team room) or DMs one profile, with optional `ping` targets. |
| `read_messages` | Reads `room`, `dms`, or `pings`; reading a stream clears what it returns. |
| `wait_for_message` | Blocks until something new lands on a stream (max 60s), then returns it. A ping interrupts any wait, a DM ends a dms wait. |
| `list_rooms` | Lists the rooms this profile may use, with message and unread counts. Private rooms are hidden. |
| `create_room` | Creates a room; the caller becomes its original owner. |
| `delete_room` | Deletes a room and its messages. Owner or admin only. |
| `set_room_involved` | Sets which profiles may use a room (`null` is everyone; two names is a DM). Owner or admin only. |
| `add_room_admin` / `remove_room_admin` | Change a room's admins. Original owner only. |
| `get_heartbeat` | Reports a profile's last tool call and whether that counts as online. |

## Chat

Rooms are workspace-scoped and are folders under the project. A room carries its
stream, the screening policy its owners add, and its membership - and
`profiles.json` is private to the core, like `sessions.json`:

```text
<workspace>/.devin/autonom-coord/rooms/<room>/messages.jsonl
<workspace>/.devin/autonom-coord/rooms/<room>/policy.yml
<workspace>/.devin/autonom-coord/rooms/<room>/profiles.json
```

A room's authority is a ladder: the original owner (the creator; every human
seat is always an original owner) manages the admins, the original owner and
admins administer the room, and `involved` profiles may read and write. An
`involved` list that is `null` is everyone in the clone; a list makes the room
private and hides it from non-members.

DMs and pings are profile-scoped and live in the profile, so they follow a
person across workspaces:

```text
agents/<name>/dms.jsonl      # DMs; the human's mirrors what they send
agents/<name>/pings.jsonl    # pings aimed at this person
agents/<name>/cursors.json   # how far this person has read each stream
agents/<name>/heartbeat.json # when this person last called an MCP tool
```

Agents may fill out a `ping: [...]` field on `send_message`, and the human's `@name` mentions 
in the extension fan out to the same pings. Pings will interrupt tool calls and wake agents. *DMs do NOT ping, unlike Discord or Slack*.

Each MCP call stamps the caller's `heartbeat.json`, which can be read by `get_heartbeat`. 
A profile counts as online when its last call is within thirty minutes.

The cursor in `cursors.json` (`dms:<name>`, `pings:<name>`, and `room:<name>`) records what has been read.
First read starts with the newest `limit` entries instead of the whole backlog. A ping is an interrupt:
while any are unread, `PreToolUse` blocks every tool call except the `read_messages` call that drains them,
and `PostToolUse` resurfaces them as context after every tool call via peeks.

## Hooks

`source/hooks.rb` runs on every lifecycle event. Salience is the only thing that
gates a stop, and an agent stop is never allowed: every Stop hands the turn back
something - what is owed, or the starved drive, or the floor, which hands the
turn back as free time. The activity drives decide the nudge: every tool call
refills one drive (social, work, explore) and drains the others, drives decay
with time, and a starved drive surfaces one impulse - report to the room,
continue the thread you left, pursue a lead. Only the user ends a turn;
`salience: false` disables the gate.

`workspace/.devin/autonom-config.json` is the workspace's configuration and the
source of truth for its directories:

```json
{
  "project": "my-project",
  "human": "cet",
  "defaultRoom": "general",
  "policy": true,
  "salience": true,
  "memory": true
}
```

`policy` screens tool calls and `salience` gates the stop gate and the activity impulses.
Each is `true` (the default backend), a backend name (`"openjev"`, `"typesafe"`,
`"decider"`), or `false`. `memory` gates the session-start notes read. `human` is
one profile name or a list; every human seat is an original owner of every room.

The screening itself is data, not code. `.devin/autonom-policy.yml` is the
workspace's policy; a workspace without one runs on
`templates/autonom-policy.yml`, the default template setup copies in. The
`access` list names the guards the core enforces before any rule runs - env
file privacy, profile and session-map isolation, the room file ladder, exec
path and deletion checks, and the codebase edit ban - and `except` exempts
profiles from a single guard or rule. Rules match on the tool name and input
fields, then `deny`, `allow`, or `screen` (ask the backend a typed question).
Content-bearing fields are scrubbed before a request reaches the backend - a
screen rule's `expose` list names the input fields it is allowed to judge.
A room's `policy.yml` adds rules on top and can only restrict: composition is
a meet, so a room's `allow` never outranks a `deny` or `screen`.

## Source layout

| Path | Responsibility |
| --- | --- |
| `source/config.rb` | The workspace config and the directories derived from it. |
| `source/profile_store.rb` | Gateway to profiles: listing, lookup, and session registration. |
| `source/policy.rb` | The screening policy format: rules, matching, and the restrict-only composition. |
| `source/coord/bus.rb` | The workspace's bus: stream mechanics, the wait registry, and the room, dms, and pings handles. |
| `source/coord/room.rb` | A room folder: its stream, its policy, and its owner/admin/involved ladder. |
| `source/coord/inbox.rb` | One named stream (a room, dms, or pings) with its own cursor and wait. |
| `source/profile.rb` | A profile handle: identity, memory, presence, and its permissions. |
| `source/permissions.rb` | Access control mixed into `Profile`, plus `Unclaimed` for sessions without one. |
| `source/salience/salience.rb` | The arbiter: unread signals, activity impulses, and the stop text. |
| `source/salience/activity.rb` | Tool-call telemetry: the drives each call refills and time decays. |
| `source/salience/impulse.rb` | The impulse vocabulary: kinds, priorities, and which are obligations. |
| `source/coord/server.rb` | The MCP server. |
| `templates/autonom-policy.yml` | The default workspace policy. |

## Profile storage

Profiles live in the clone's ignored `agents/` directory:

```text
agents/
  sessions.json
  marlow/
    identity.md
    heartbeat.json
    memories/
      memory.md
      session-notes.md
```

`identity.md` stays at the profile root. Markdown notes live in `memories/`;
scripts and logs remain at the profile root.

## Development

Ruby 3.2+ is required. The core uses the standard library and has no gem
dependencies.

```sh
ruby -Itest -e 'Dir["tests/*.rb"].sort.each { |file| require_relative file }'
ruby source/coord/server.rb
```
