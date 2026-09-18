# agent-coord

A workspace-agnostic toolkit for running multi-agent teams on top of
[`agent-coord-mcp`](https://github.com/davidbalzan/agent-coord-mcp). One repo holds
the canonical implementation — the chat UI, lifecycle hooks, coordination tools,
skill templates, and the global identity registry — and `bin/coord` wires any
workspace into it with a single command.

> **Status:** this project is currently primarily vibe coded — built fast, by
> agents, for agents. It works (three workspaces run on it daily), but a proper
> review and rewrite pass is intended before it should be considered settled
> design.

## What it gives a workspace

| Piece | What it is |
| --- | --- |
| Chat UI | A browser team room for the human: rooms, DMs, `@seat`/`@display`/`#room` pings, merged message runs, recess and stand-down controls, live-reconnecting SSE feed. Served per workspace on its own port. |
| Lifecycle hooks | Session-start identity + personality + memory injection, prompt context, and a keep-alive Stop hook so seats stay reachable. |
| `bin/coord` | The CLI: `init`, `seat add`, `chat start/stop/status/restart`, `update`, `identity add`. |
| Identity registry | `agents/<name>/` holds `identity.md` + `memory.md` — global and portable, so an identity carries its self across workspaces. |
| Rendered skills | Per-project `<project>-team` and `<project>-recess` skills generated at init. |
| Docs | `COORDINATION.md` and `ORGANICS.md` planted at the workspace root on first init. |

Workspaces keep only configuration and state: `.devin/coord.json` plus the bus
state under `.devin/agent-coord/state/`. Everything executable is symlinked or
rendered from this repo, so every workspace upgrades together.

## Requirements

- Node.js 22+
- `npm ci` in this repo — installs the pinned `agent-coord-mcp` dependency
  (the bus itself: per-seat MCP processes over a shared file-backed state dir).

## Quick start

```sh
bin/coord init /path/to/workspace --seats a:rose,b:jane
bin/coord chat start /path/to/workspace
```

`init` allocates a chat port from `ports.json`, writes `.devin/coord.json` and
the per-seat `mcp_config.json` entries, symlinks `chat`/`hooks`/`tools`, renders
the two skills, plants `COORDINATION.md` + `ORGANICS.md`, and appends the
coordination block to `AGENTS.md`. `chat start` brings the UI up on the
allocated port.

```sh
bin/coord seat add /path/to/workspace c:patrick   # wire another seat to an identity
bin/coord identity add ada                        # register a new global identity
bin/coord update /path/to/workspace               # verify links + rendered skills
```

## Layout

| Path | Contents |
| --- | --- |
| `bin/coord` | The CLI — all wiring logic lives here. |
| `core/chat/` | Chat server + web client (voice-free). |
| `core/hooks/` | `session-start`, `prompt-context`, `keep-alive`, `coord` helper. |
| `core/tools/` | `coord-web`, `coord-chat`, `coord-recess` workspace scripts. |
| `core/skills/` | `team` and `recess` skill templates (rendered per project). |
| `agents/` | Global identity registry — one dir per named agent. |
| `templates/` | `coord.json`, `mcp_config.json`, `hooks.v1.json`, `AGENTS-block`, the two workspace docs. |
| `ports.json` | Chat-port allocations per workspace. |

## How it fits together

Each seat is an `agent-coord-mcp` process bound to an identity, sharing one
file-backed state directory. The human talks through the chat UI rather than any
seat's own window; `@`-mentions fan out to seat inboxes, `#room` pings every
member. Hooks read `coord.json` at session start to inject the seat's identity,
personality, and memory tail — so a new tab lands oriented. Legacy seat ids
(`<project>-a` style) resolve to their mapped identities, so sessions started
before an identity rename keep working.
