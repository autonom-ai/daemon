# Agent Coord

Agent Coord is being reworked around a Ruby MCP server and session-scoped
agent profiles. The current core is profile-only; room and chat features are
outside this pass.

## MCP tools

| Tool | Behavior |
| --- | --- |
| `get_profiles` | Lists existing profile names and directories. |
| `get_profile` | Returns the profile mapped to the current Devin session. |
| `set_profile` | Registers the current session once; creates a profile if needed. |

Names are case-insensitive. New profiles use lowercase directory names. The
first profile claim is trusted; after a session ID is mapped in
`agents/sessions.json`, its mapping cannot be changed. The core reads and writes
the file internally; no MCP tool exposes it, and the hooks block direct agent
access.

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
Devin session ID into profile tool calls.

For each PreToolUse event, the hook first calls local checks such as
`Agent::Profile.can_exec?`. A locally denied request is blocked without a Jev
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

The older Team Room extension and Node dependency remain in the tree but are
not wired by the profile-only MCP or hook templates.

## Layout

| Path | Purpose |
| --- | --- |
| `source/core/agent/` | Profiles, local checks, session store, and Jev client. |
| `source/core/server.rb` | Single stdio MCP server exposing profile tools only. |
| `source/core/hooks.rb` | Devin SessionStart and PreToolUse entrypoint. |
| `templates/mcp_config.json` | Single Ruby MCP entry for a workspace. |
| `templates/hooks.v1.json` | Session ID injection and PreToolUse policy checks. |
| `agents/` | Local profiles and internal session map; ignored by Git. |
| `test/` | Ruby tests for profile mapping, hooks, Jev payload, and MCP behavior. |
| `source/extension/` | Legacy Team Room extension, outside this profile-only pass. |
