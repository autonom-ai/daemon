# Autonom

Autonom is a Ruby coordination and policy core for multi-agent workspaces. All
model access goes through a small TypeScript AI gateway (policy decisions now,
sidekicks later); coordination, profiles, hooks, permissions, and policy
composition remain Ruby.

There is no workspace config file. Paths are fixed relative to
`DEVIN_PROJECT_DIR` (or the current directory), rooms are always explicit, and
the one human profile is always named `human`.

## Setup

Requirements:

- Ruby 3.2+
- Node.js 22+

Install and build the AI gateway:

```sh
npm ci
npm run build
```

Merge `templates/mcp.json` into the workspace MCP configuration and replace
`{{AUTONOM_ROOT}}`. The server names are part of the hook contract:

```json
{
  "mcpServers": {
    "autonom-coord": {
      "command": "ruby",
      "args": ["<AUTONOM_ROOT>/source/coord/server.rb"]
    },
    "autonom-policy": {
      "command": "ruby",
      "args": ["<AUTONOM_ROOT>/source/policy/server.rb"]
    }
  }
}
```

Copy the appropriate hook template from `templates/devin/` or
`templates/claude/` and replace `{{COORD_ROOT}}` with this clone's path.
Copy `templates/policy.yml` to the workspace's `.devin/policy.yml`; the primary
policy is required, and a missing file blocks tool use rather than loading a template.

## Coordination

`autonom-coord` identifies each agent through the Devin session ID injected by
the hook. A session claims one profile with `set_profile` and cannot change it.
The `human` profile is created automatically and cannot be claimed by an agent
session.

| Tool | Behavior |
| --- | --- |
| `get_profiles` | Lists profile names and directories. |
| `get_profile` | Returns the current session's profile. |
| `set_profile` | Registers the current session once. |
| `send_message` | Posts to an explicit room or DMs one profile, with optional pings. |
| `read_messages` | Reads room, DM, or ping streams. Room reads require `room`. |
| `wait_for_message` | Waits on an explicit room or on DMs for up to 60 seconds. |
| `list_rooms` | Lists visible rooms and unread counts. |
| `create_room` / `delete_room` | Creates or removes a room. |
| `set_room_involved` | Sets room membership. |
| `add_room_admin` / `remove_room_admin` | Changes room administrators. |
| `get_heartbeat` | Reports profile presence from MCP activity. |

Rooms live under the workspace:

```text
<workspace>/.devin/autonom-coord/rooms/<room>/messages.jsonl
<workspace>/.devin/autonom-coord/rooms/<room>/policy.yml
<workspace>/.devin/autonom-coord/rooms/<room>/profiles.json
```

DMs, pings, cursors, heartbeat, and last-room focus live directly in each
profile:

```text
agents/<name>/identity.md
agents/<name>/dms.jsonl
agents/<name>/pings.jsonl
agents/<name>/cursors.json
agents/<name>/heartbeat.json
agents/<name>/room.json
```

Every room-scoped tool requires `room`; there is no default room. A successful
room post records that room, keyed by workspace, in the posting profile's
`room.json`. This selects the profile's active room policy until it posts in
another room. This state is maintained by the core, not editable by agent tools.

## Policy

`autonom-policy` is independent of the coordination MCP. It manages secondary
`policy.yml` files by path, without a separate policy directory or registry:

| Tool | Behavior |
| --- | --- |
| `check_policy` | Checks a request against primary policy and an optional secondary path injected by the hook. |
| `set_secondary_policy` | Creates or replaces `policy.yml` at an existing directory path. |
| `list_secondary_policies` | Lists accessible `policy.yml` files beneath the supplied `directory`. |
| `remove_secondary_policy` | Removes the secondary `policy.yml` at the supplied `path`. |

The primary policy is the required `.devin/policy.yml`; there is no template
fallback. A room's `policy.yml` stays in its room directory. To set policy for
room `general`, pass `.devin/autonom-coord/rooms/general/policy.yml` as `path`.
Room members may read its policy, while only the owner or admins may change it.
The hooks apply this room policy to every tool call after the profile last posts
there, until it posts in another room. Secondary policies add restrictions but
cannot grant past a primary denial or screen.

Policy files contain access guards and ordered rules. Rules match the tool name
and input fields, then `deny`, `allow`, or `screen`. Screen rules have one plain
language `question`; content-bearing fields are removed before the model call
unless the rule explicitly names them in `expose`.

All model access goes through `source/gateway.ts`, an AI SDK bridge invoked
as `node dist/gateway.js`. It reads a JSON request on stdin and writes the
result on stdout:

| Field | Meaning |
| --- | --- |
| `model` | An alias (`policy`) or a `provider/model` spec; optional, defaults to the policy model. |
| `prompt` / `messages` | A single prompt or a message list; exactly one is required. |
| `system` | Optional system instructions. |
| `schema` | Optional JSON schema; the reply is `{ "output": ... }` instead of `{ "text": ... }`. |
| `timeout` | Milliseconds before the request aborts; defaults to 30000. |
| `maxRetries` | Provider retry count; the policy decision disables retries. |
| `maxOutputTokens`, `providerOptions` | Optional pass-through to the provider call. |

The `PROVIDERS` hash in `source/gateway.ts` defines supported providers and
their AI SDK packages: `openrouter`, `zen`, `anthropic`, `codex`, and `local`
(Ollama). API keys are the only gateway configuration; they live in this
clone's `.env` (`OPENROUTER_API_KEY`, `OPENCODE_API_KEY`, `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`). `AUTONOM_<PROVIDER>_BASE_URL` overrides a provider's base
URL, e.g. `AUTONOM_OPENROUTER_BASE_URL`.

## Hooks and salience

`source/hooks.rb` injects identity, team, room, and unread-message context. It
does not provide native memory storage or simulate activity drives. Stop
handling is deliberately process-oriented: answer obligations first, continue
the current user task, verify or coordinate concrete work, and wait only when
the task is genuinely blocked.

Unread pings interrupt tool use until the profile drains its ping stream. Every
pre-tool call first enforces deterministic permissions, then primary policy,
then the secondary policy selected by the profile's last posted room.

## Development

```sh
npm run check
npm run build
ruby -Itests -e 'Dir["tests/**/*.rb"].sort.each { |file| require_relative file }'
```

Source layout:

| Path | Responsibility |
| --- | --- |
| `source/coord/` | Rooms, streams, waits, and the coordination MCP. |
| `source/policy.rb` | Policy parsing, storage, matching, and composition. |
| `source/policy/server.rb` | The policy MCP. |
| `source/gateway.ts` | AI SDK gateway: providers, models, and generation. |
| `source/gateway.rb` | Ruby gateway invocation. |
| `source/decision.rb` | Policy decision requests and request scrubbing. |
| `source/hooks.rb` | Lifecycle context, session injection, and enforcement. |
| `source/profile_store.rb` | Profile discovery and session registration. |
| `source/permissions.rb` | Deterministic file and command guards. |
| `source/salience/salience.rb` | Strict task and coordination context. |
