# agent-coord

> [!WARNING]
>
> This project is primarily vibe coded as it stands. It works and it's in daily
> use, but it hasn't had a proper review pass — I intend to do a rewrite and
> review, so treat the code accordingly until then.

A workspace-agnostic toolkit for running multi-agent teams on top of
[`agent-coord-mcp`](https://github.com/davidbalzan/agent-coord-mcp). The clone
is the whole install: the Team Room extension, lifecycle hooks, coordination
tools, skill templates, and the identity registry (`agents/`). There is no
machine-global state — nothing lives under `~/.local/state` — and no init
machinery: a workspace is wired by hand with three files, shown in
`templates/`.

## What a workspace gets

| Piece | What it is |
| --- | --- |
| Team Room | The human's seat, as a Devin Desktop extension (`extension/`): rooms, DMs, `@name`/`#room` pings, and merged message runs. It reads the workspace's bus directly — no server, no port, no browser. |
| Lifecycle hooks | Session-start identity + personality + memory injection, prompt context, a keep-alive Stop hook so agents stay reachable, and identity claims recorded from the join. |
| `bin/coord` | The CLI: `identity add` (scaffold `agents/<name>/`). |
| Identity registry | `agents/<name>/` in this clone holds `identity.md` + `memory.md` — the person follows the name across every workspace wired to this clone. |
| Skills | `core/skills/team`, copied per workspace with `{{PROJECT}}` filled in. |
| Docs | `COORDINATION.md` and `ORGANICS.md` copied to the workspace root. |

**There are no seats.** An agent's name is its identity — `join` binds the
session's MCP process to that name for its lifetime, and the bus refuses a
second live claim on a name already running. Devin Desktop shares one stdio
MCP process across every tab in a workspace, so each roster member gets its
own `agent-coord-<name>` server entry, pre-bound by `AGENT_COORD_BOUND_AGENT`.
There is deliberately no generic `agent-coord` entry — an unbound server
TOFU-locks to whichever name calls it first, so a tab that is not on the
roster simply has no entry.

**Identity is never guessed.** The `record-join` PostToolUse hook watches for a
successful `join` through this tab's own `agent-coord-<name>` entry and records
that as the session's claim under `.devin/agent-coord/claims/`; every other
hook reads the claim back, and a tab that has not joined is told to join rather
than assigned someone else's name. (The previous ancestry heuristic could not
tell tabs apart — the client root is shared — and froze a stranger's name into
the claim file.)

## Requirements

- Node.js 22+
- `npm ci` in this clone — installs the pinned `agent-coord-mcp` dependency
  (the bus itself: one MCP process per tab over a shared file-backed state dir).
- The Team Room extension, installed into Devin Desktop (see below).

## Wiring a workspace

No init — copy three files into the workspace's `.devin/` and fill in the
`{{…}}` placeholders (each file in `templates/` explains its own):

| File | From | Fill in |
| --- | --- | --- |
| `.devin/coord.json` | `templates/coord.json` | project, human, roster, coordRoot |
| `.devin/mcp_config.local.json` | `templates/mcp_config.json` | `{{COORD_ROOT}}`, `{{WORKSPACE}}`, one `agent-coord-<name>` per roster member |
| `.devin/hooks.v1.json` | `templates/hooks.v1.json` | `{{COORD_ROOT}}` |

Optional, all by hand:

```sh
cp -r <clone>/core/skills/team <ws>/.devin/skills/<project>-team # then substitute {{PROJECT}}
cp <clone>/templates/{COORDINATION.md,ORGANICS.md} <ws>/
```

There is intentionally no AGENTS.md template — an agent should only assume it
is on a team when it is actually told so (the session-start hook says it, the
room says it). If you want AGENTS.md to say it too, write that yourself.

`.devin/agent-coord/state/` (the bus) is created on first use. One seed is
required. The bus refuses to start without a configured transport — write
`{"transport": "tmux-push-remote"}` to `.devin/agent-coord/state/config.json`
(`herdr` instead if that binary is installed; this fleet never attaches, so
the choice is inert either way).

## Running

```sh
bin/coord identity add ada                  # scaffold agents/ada/{identity,memory}.md here
```

The Team Room:

```sh
cd extension && npx @vscode/vsce package --no-dependencies   # writes coord-room-<version>.vsix
# install it: extract into ~/.devin/extensions/cet.coord-room-<version>/ (or a VSIX install command)
```

Then open a wired workspace in Devin Desktop and reload the window — the room
opens as an editor tab (click the status-bar item, or run `Team Room: Open the
team room`). The activity-bar view is the same UI in the sidebar, reachable via
`Team Room: Open the team room in the sidebar`. It resolves the workspace from
the open folder's `.devin/coord.json`; if the store module is missing, the view
says so, retries with backoff, and `npm ci` in this clone fixes it without a
reload.

## Layout

| Path | Contents |
| --- | --- |
| `extension/` | The Team Room — Devin Desktop extension (host bus client + webview UI). |
| `bin/coord` | The CLI — identity scaffolding. |
| `core/chat/` | Shared room actions (`actions.mjs`), used by the extension. |
| `core/hooks/` | `session-start`, `prompt-context`, `keep-alive`, `record-join`, and `coord` helper. |
| `core/skills/` | `team` skill template (copied per project). |
| `templates/` | The three wiring files and the two workspace docs. |
| `agents/` | Identity registry — `identity.md` + `memory.md` per person. Gitignored; local to this clone. |

## How it fits together

Each tab runs its `agent-coord-<name>` MCP entry — one stdio process per
server entry, sharing a file-backed state directory with its teammates. `join`
claims the agent's name for the session; the name is the identity, and the bus
refuses a second live claim on one already running. The human talks through the
Team Room rather than any agent's own window; `@`-mentions fan out to inboxes,
`#room` pings every member.

Hooks read `coord.json` at session start to inject the agent's personality and
memory, and the claim file survives context resets, so a wiped tab still knows
who it is. Retired bound ids
(`<project>-a` style) still resolve through coord.json's `identities` map.
