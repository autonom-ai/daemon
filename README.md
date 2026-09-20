# agent-coord

> [!WARNING]
>
> This project is primarily vibe coded as it stands. It works and it's in daily
> use, but it hasn't had a proper review pass — I intend to do a rewrite and
> review, so treat the code accordingly until then.

A workspace-agnostic toolkit for running multi-agent teams on top of
[`agent-coord-mcp`](https://github.com/davidbalzan/agent-coord-mcp). The clone
is the whole install: chat UI, lifecycle hooks, coordination tools, skill
templates, the identity registry (`agents/`), and the chat-port table
(`ports.json`). There is no machine-global state — nothing lives under
`~/.local/state` — and no init machinery: a workspace is wired by hand with
three files, shown in `templates/`.

## What a workspace gets

| Piece | What it is |
| --- | --- |
| Chat UI | A browser team room for the human: rooms, DMs, `@name`/`#room` pings, merged message runs, recess and stand-down controls, live-reconnecting SSE feed. Served per workspace on its own port. |
| Lifecycle hooks | Session-start identity + personality + memory injection, prompt context, and a keep-alive Stop hook so agents stay reachable. |
| `bin/coord` | The CLI: `chat start/stop/status/restart`, `identity add`. |
| Identity registry | `agents/<name>/` in this clone holds `identity.md` + `memory.md` — the person follows the name across every workspace wired to this clone. |
| Skills | `core/skills/team` and `core/skills/recess`, copied per workspace with `{{PROJECT}}` filled in. |
| Docs | `COORDINATION.md` and `ORGANICS.md` copied to the workspace root. |

**There are no seats.** An agent's name is its identity — `join` binds the
session's MCP process to that name for its lifetime, and the bus refuses a
second live claim on a name already running. Devin Desktop shares one stdio
MCP process across every tab in a workspace, so each roster member gets its
own `agent-coord-<name>` server entry, pre-bound by `AGENT_COORD_BOUND_AGENT`.
There is deliberately no generic `agent-coord` entry — an unbound server
TOFU-locks to whichever name calls it first, so a tab that is not on the
roster simply has no entry. Session claims under `.devin/agent-coord/claims/`
let hooks reassert who a tab is after a context reset.

## Requirements

- Node.js 22+
- `npm ci` in this clone — installs the pinned `agent-coord-mcp` dependency
  (the bus itself: one MCP process per tab over a shared file-backed state dir).

## Wiring a workspace

No init — copy three files into the workspace's `.devin/` and fill in the
`{{…}}` placeholders (each file in `templates/` explains its own):

| File | From | Fill in |
| --- | --- | --- |
| `.devin/coord.json` | `templates/coord.json` | project, human, roster; `port: null` auto-allocates |
| `.devin/mcp_config.local.json` | `templates/mcp_config.json` | `{{COORD_ROOT}}`, `{{WORKSPACE}}`, one `agent-coord-<name>` per roster member |
| `.devin/hooks.v1.json` | `templates/hooks.v1.json` | `{{COORD_ROOT}}` |

Optional, all by hand:

```sh
ln -s <clone>/core/tools/coord-* <ws>/tools/          # the tools/coord-* names docs reference
cp -r <clone>/core/skills/team <ws>/.devin/skills/<project>-team     # then substitute {{PROJECT}}
cp -r <clone>/core/skills/recess <ws>/.devin/skills/<project>-recess # same
cp <clone>/templates/{COORDINATION.md,ORGANICS.md} <ws>/
```

There is intentionally no AGENTS.md template — an agent should only assume it
is on a team when it is actually told so (the session-start hook says it, the
room says it). If you want AGENTS.md to say it too, write that yourself.

`.devin/agent-coord/state/` (the bus) and `.devin/collaboration/` (stand-down
and recess markers) are created on first use. One seed is required: the bus
refuses to start without a configured transport — write
`{"transport": "tmux-push-remote"}` to `.devin/agent-coord/state/config.json`
(`herdr` instead if that binary is installed; this fleet never attaches, so
the choice is inert either way).

## Running

```sh
bin/coord chat start /path/to/workspace     # serve the room UI on its port
bin/coord chat status /path/to/workspace
bin/coord chat stop /path/to/workspace
bin/coord identity add ada                  # scaffold agents/ada/{identity,memory}.md here
```

## Layout

| Path | Contents |
| --- | --- |
| `bin/coord` | The CLI — chat lifecycle and identity scaffolding. |
| `core/chat/` | Chat server + web client (voice-free). |
| `core/hooks/` | `session-start`, `prompt-context`, `keep-alive`, `coord` helper. |
| `core/tools/` | `coord-web`, `coord-chat`, `coord-recess` workspace scripts. |
| `core/skills/` | `team` and `recess` skill templates (copied per project). |
| `templates/` | The three wiring files and the two workspace docs. |
| `agents/` | Identity registry — `identity.md` + `memory.md` per person. Gitignored; local to this clone. |
| `ports.json` | Chat-port allocations per workspace. Gitignored. |

## How it fits together

Each tab runs its `agent-coord-<name>` MCP entry — one stdio process per
server entry, sharing a file-backed state directory with its teammates. `join` claims the
agent's name for the session; the name is the identity, and the bus refuses a
second live claim on one already running. The human talks through the chat UI
rather than any agent's own window; `@`-mentions fan out to inboxes, `#room`
pings every member. Hooks read `coord.json` at session start to inject the
agent's personality and memory tail — and the claims dir survives context
resets, so a wiped tab still knows who it is. Retired bound ids
(`<project>-a` style) still resolve through coord.json's `identities` map.
