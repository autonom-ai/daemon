# agent-coord

> [!WARNING]
>
> This project is primarily vibe coded as it stands. It works and it's in daily
> use, but it hasn't had a proper review pass — I intend to do a rewrite and
> review, so treat the code accordingly until then.

A workspace-agnostic toolkit for running multi-agent teams on top of
[`agent-coord-mcp`](https://github.com/davidbalzan/agent-coord-mcp). One repo holds
the canonical implementation — the chat UI, lifecycle hooks, coordination tools,
and skill templates — and `bin/coord` wires any workspace into it with a single
command. Identities, memories, and port allocations live in machine-local state,
never in this repo.

## What it gives a workspace

| Piece | What it is |
| --- | --- |
| Chat UI | A browser team room for the human: rooms, DMs, `@name`/`#room` pings, merged message runs, recess and stand-down controls, live-reconnecting SSE feed. Served per workspace on its own port. |
| Lifecycle hooks | Session-start identity + personality + memory injection, prompt context, and a keep-alive Stop hook so agents stay reachable. |
| `bin/coord` | The CLI: `init`, `agent add`, `chat start/stop/status/restart`, `update`, `identity add`. |
| Identity registry | `~/.local/state/agent-coord/agents/<name>/` holds `identity.md` + `memory.md` — global and portable, so an identity carries its self across workspaces. |
| Rendered skills | Per-project `<project>-team` and `<project>-recess` skills generated at init. |
| Docs | `COORDINATION.md` and `ORGANICS.md` planted at the workspace root on first init. |

Workspaces keep only configuration and state: `.devin/coord.json`, the single
`agent-coord` entry in `.devin/mcp_config.local.json`, plus the bus state under
`.devin/agent-coord/state/`. Everything executable is symlinked or rendered
from this repo, so every workspace upgrades together.

**There are no seats.** An agent's name is its identity — `join` binds the
session's MCP process to that name for its lifetime (no env binding, no
per-seat server entries), and the bus refuses a second live claim on a name
already running. Session claims under `.devin/agent-coord/claims/` let hooks
reassert who a tab is after a context reset.

## Requirements

- Node.js 22+
- `npm ci` in this repo — installs the pinned `agent-coord-mcp` dependency
  (the bus itself: one MCP process per tab over a shared file-backed state dir).

## Quick start

```sh
bin/coord init /path/to/workspace --agents ada,grace
bin/coord chat start /path/to/workspace
```

`init` allocates a chat port (tracked in
`~/.local/state/agent-coord/ports.json`), writes `.devin/coord.json` and the
single `agent-coord` entry in `.devin/mcp_config.local.json` (removing any
legacy `agent-coord-*` seat entries), symlinks `chat`/`hooks`/`tools`, renders
the two skills, plants `COORDINATION.md` + `ORGANICS.md`, and appends the
coordination block to `AGENTS.md`. `chat start` brings the UI up on the
allocated port.

```sh
bin/coord agent add /path/to/workspace linus    # add an agent to the roster + scaffold its identity
bin/coord identity add ada                      # register a new global identity
bin/coord update /path/to/workspace             # verify links, MCP wiring, rendered skills
```

## Layout

| Path | Contents |
| --- | --- |
| `bin/coord` | The CLI — all wiring logic lives here. |
| `core/chat/` | Chat server + web client (voice-free). |
| `core/hooks/` | `session-start`, `prompt-context`, `keep-alive`, `coord` helper. |
| `core/tools/` | `coord-web`, `coord-chat`, `coord-recess` workspace scripts. |
| `core/skills/` | `team` and `recess` skill templates (rendered per project). |
| `templates/` | `coord.json`, `mcp_config.json`, `hooks.v1.json`, `AGENTS-block`, the two workspace docs. |

Machine-local state (never committed, override with `AGENT_COORD_HOME`):

| Path | Contents |
| --- | --- |
| `~/.local/state/agent-coord/agents/` | Global identity registry — one dir per named agent (`identity.md` + `memory.md`). |
| `~/.local/state/agent-coord/ports.json` | Chat-port allocations per workspace. |

## How it fits together

Each tab runs the same `agent-coord` MCP entry — one stdio process sharing a
file-backed state directory with its teammates. `join` claims the agent's name
for the session; the name is the identity, and the bus refuses a second live
claim on one already running. The human talks through the chat UI rather than
any agent's own window; `@`-mentions fan out to inboxes, `#room` pings every
member. Hooks read `coord.json` at session start to inject the agent's
personality and memory tail — and the claims dir survives context resets, so a
wiped tab still knows who it is. Retired bound ids (`<project>-a` style) still
resolve through coord.json's `identities` map.
