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
scripts and logs remain at the profile root. Migrate existing root-level
Markdown files, except `identity.md`, with:

```sh
ruby -r ./source/core/agent/store.rb -e 'Agent::Store.migrate_memories!'
```

## Devin hooks and Jev

Wire the workspace by hand. Add an MCP entry named `agent-coord` — the name
matters, because the hooks match `mcp__agent-coord__*` — running
`ruby <clone>/source/core/server.rb`, then copy `templates/hooks.v1.json` into
the workspace's `.devin/` directory and replace `{{COORD_ROOT}}` with this
clone's absolute path. The hooks inject the Devin session ID into profile tool
calls and carry the session lifecycle:

| Event | What it does |
| --- | --- |
| `SessionStart` | Hands the tab its identity, memory slice, team room, recent room traffic, and teammates' leanings. |
| `UserPromptSubmit` | Nudges with what is waiting (pings, DMs, room traffic) without draining it. |
| `PreToolUse` | Local permission checks, then Jev, then session ID injection. |
| `PostToolUse` | Delivers unread pings; never blocks a tool. |
| `Stop` | Refuses the stop while the team does not idle, handing back what is waiting. `.devin/collaboration/stand-down` is the release valve. |

Workspaces wired before these hooks existed need the `UserPromptSubmit` and
`Stop` entries added to their `.devin/hooks.v1.json`. The Jev policy check runs
for a workspace unless its `coord.json` sets `"jev": false`.

For each PreToolUse event, the hook first calls local checks such as
`Agent::Profile.permissions.can_exec?`. A locally denied request is blocked without a Jev
request. Jev screens requests that pass; API failures block, and noul scores of
0.5 or higher are denied.

Set `OPENJEV_API_KEY` in the hook process environment or this clone's ignored
`.env` file. Jev receives the tool name and filtered arguments, not the session
ID or file contents. Common credential patterns in shell commands are
redacted, but commands may contain other sensitive text; use this integration
only where sending that request text to OpenJEV is acceptable.

Hooks protect normal Devin tool calls, not arbitrary processes or sessions
where hooks are disabled. Jev is a model judgment layer, not a deterministic
security boundary; local path and session checks remain authoritative.

## Team Room extension

`source/extension/` is the human's seat in Devin Desktop: the room list, 1:1
DMs, and ping notifications. It reads and writes the same files the core does —
rooms in the workspace, DMs and pings in the human's profile — with no server in
between.

Policy screening (Jev) currently runs in the `PreToolUse` hook. The plan is to
move it into the extension's sidebar UI, so a human can see and judge a request
there instead. Until that lands, `"jev": false` in a workspace's `coord.json`
turns the hook check off for that workspace.

## Development

Ruby 3.2+ is required. The core uses the standard library and has no gem
dependencies.

```sh
ruby -Itest -e 'Dir["test/*.rb"].sort.each { |file| require_relative file }'
ruby source/core/server.rb
```

## Layout

| Path | Purpose |
| --- | --- |
| `source/core/agent/` | Profiles, identity and memory, local checks, waiters, session and heartbeat store, and Jev client. |
| `source/core/room.rb` | Workspace-scoped rooms. |
| `source/core/server.rb` | Single stdio MCP server exposing profile, chat, and heartbeat tools. |
| `source/core/hooks.rb` | Devin lifecycle hooks: session context, nudges, policy checks, ping delivery, and the no-idle stop. |
| `templates/hooks.v1.json` | The lifecycle hook wiring for a workspace. |
| `agents/` | Local profiles, chat streams, and the internal session map; ignored by Git. |
| `test/` | Ruby tests for profiles, rooms, identity, hooks, Jev payload, and MCP behavior. |
| `source/extension/` | Team Room extension: rooms, DMs, and pings for the human. |
