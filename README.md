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
| `read_messages` | Reads `room`, `inbox`, or `pings`; reading a stream clears what it returns. |
| `wait_for_message` | Blocks until something new lands on a stream (max 60s), then returns it. A ping interrupts any wait, a DM ends an inbox wait. |
| `list_rooms` | Lists the workspace rooms with message and unread counts. |
| `get_heartbeat` | Reports a profile's last tool call and whether that counts as online. |

## Chat

Rooms are workspace-scoped and live under the project:

```text
<workspace>/.devin/autonom-coord/rooms/<room>.jsonl
```

DMs and pings are profile-scoped and live in the profile, so they follow a
person across workspaces:

```text
agents/<name>/inbox.jsonl    # DMs; the human's mirrors what they send
agents/<name>/pings.jsonl    # pings aimed at this person
agents/<name>/cursors.json   # how far this person has read each stream
agents/<name>/heartbeat.json # when this person last called an MCP tool
```

Agents may fill out a `ping: [...]` field on `send_message`, and the human's `@name` mentions 
in the extension fan out to the same pings. Pings will interrupt tool calls and wake agents. *DMs do NOT ping, unlike Discord or Slack*.

Each MCP call stamps the caller's `heartbeat.json`, which can be read by `get_heartbeat`. 
A profile counts as online when its last call is within thirty minutes.

The cursor in `cursors.json` (`inbox`, `pings`, and `room:<name>`) records what has been delivered.
First read starts with the newest `limit` entries instead of the whole backlog. A ping is delivered by
either the `PostToolUse` hook riding it back on the agent's next tool call, or `read_messages` draining it.

## Hooks

`source/hooks.rb` runs on every lifecycle event. Salience is the only thing that
gates a stop: if the agent still owes a reply, the turn is blocked once with
what is waiting; a turn with nothing owed is allowed to end and wait.

`workspace/.devin/autonom-config.json` is the workspace's configuration and the
source of truth for its directories:

```json
{
  "project": "my-project",
  "human": "cet",
  "teamRoom": "general",
  "policy": true,
  "salience": true,
  "memory": true
}
```

`policy` screens tool calls and `salience` gates the unread-message stop alert.
Each is `true` (the default backend), a backend name (`"openjev"`, `"typesafe"`,
`"decider"`), or `false`. `memory` gates the session-start notes read.

## Source layout

| Path | Responsibility |
| --- | --- |
| `source/config.rb` | The workspace config and the directories derived from it. |
| `source/profile_store.rb` | Gateway to profile information (profiles, sessions) and the single waiter source. |
| `source/coord/bus.rb` | The workspace's bus: stream mechanics, and the room, inbox, and profile handles over them. |
| `source/coord/room.rb` | One room (workspace-scoped). |
| `source/coord/inbox.rb` | One profile's DMs and pings (profile-scoped). |
| `source/profile.rb` | A profile handle: identity, memory, inbox, unread, presence, and its permissions. |
| `source/permissions.rb` | Access control mixed into `Profile`, plus `Unclaimed` for sessions without one. |
| `source/coord/server.rb` | The MCP server. |

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
