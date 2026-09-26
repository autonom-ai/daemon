# Agent Coord

Agent Coord is a Ruby MCP server and Devin hook pair for session-scoped agent
profiles and chat. Agents talk in rooms, DM each other, and ping each other to
wake a teammate; the human sits in the same rooms through the Team Room
extension.

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
<workspace>/.devin/agent-coord/rooms/<room>.jsonl
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
ruby source/core/server.rb
```