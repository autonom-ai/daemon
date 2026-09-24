# Agent Coord

Agent Coord is a Ruby MCP server and Devin hook pair for session-scoped agent
profiles and chat. Agents talk in rooms, DM each other, and ping each other to
wake a teammate; the human sits in the same rooms through the Team Room
extension.

## MCP tools

| Tool | Behavior |
| --- | --- |
| `get_profiles` | Lists existing profile names and directories. |
| `get_profile` | Returns the profile mapped to the current Devin session. |
| `set_profile` | Registers the current session once; creates a profile if needed. |
| `send_message` | Posts to a room (default: the team room) or DMs one profile, with optional `ping` targets. |
| `read_messages` | Reads `room`, `inbox`, or unread `pings`; reading pings clears them. |

Names are case-insensitive. New profiles use lowercase directory names. The
first profile claim is trusted; after a session ID is mapped in
`agents/sessions.json`, its mapping cannot be changed. The core reads and writes
the file internally; no MCP tool exposes it, and the hooks block direct agent
access.

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
agents/<name>/pings.cursor   # how many pings have been delivered
```

A DM does not ping. To wake someone, name them: an agent passes `ping: [...]`
on `send_message`, and the human's `@name` mentions in the extension fan out to
the same pings. The human is a profile like anyone else, so agents can DM and
ping them.

A ping is delivered exactly once. The `PostToolUse` hook rides unread pings back
as context on the agent's next tool call and advances the cursor; `read_messages`
with `source: "pings"` drains the same stream. The extension delivers the
human's pings as a badge and a notification.

## Profile storage

Profiles live in the clone's ignored `agents/` directory:

```text
agents/
  sessions.json
  marlow/
    identity.md
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

Copy `templates/mcp_config.json` and `templates/hooks.v1.json` into a
workspace's `.devin/` directory and replace `{{COORD_ROOT}}` with this clone's
absolute path. The MCP config has one `agent-coord` entry. The hooks inject the
Devin session ID into profile tool calls, and a `PostToolUse` hook delivers
unread pings after any tool call. Ping delivery never blocks a tool. Workspaces
wired before this change need the `PostToolUse` entry added to their
`.devin/hooks.v1.json`.

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

## Development

Ruby 3.2+ is required. The core uses the standard library and has no gem
dependencies.

```sh
ruby -Itest -e 'Dir["test/*.rb"].sort.each { |file| require_relative file }'
ruby source/core/server.rb
```

The Team Room extension reads and writes the same files through
`source/extension/bus.js`. The older `source/devin` bus hooks remain in the tree
but are not wired by the MCP or hook templates.

## Layout

| Path | Purpose |
| --- | --- |
| `source/core/agent/` | Profiles, local checks, session store, and Jev client. |
| `source/core/room.rb` | Workspace-scoped rooms. |
| `source/core/server.rb` | Single stdio MCP server exposing profile and chat tools. |
| `source/core/hooks.rb` | Devin SessionStart, PreToolUse, and PostToolUse entrypoint. |
| `templates/mcp_config.json` | Single Ruby MCP entry for a workspace. |
| `templates/hooks.v1.json` | Session ID injection, policy checks, and ping delivery. |
| `agents/` | Local profiles, chat streams, and the internal session map; ignored by Git. |
| `test/` | Ruby tests for profiles, rooms, hooks, Jev payload, and MCP behavior. |
| `source/extension/` | Team Room extension: rooms, DMs, and pings for the human. |
