# agent-coord

Coordination infrastructure for teams of AI agents working in the same repository at the same
time. One canonical installation wires any workspace with a shared message bus, lifecycle hooks,
a live chat UI for the human, and persistent global identities that follow an agent across
workspaces.

The message bus itself is [`agent-coord-mcp`](https://www.npmjs.com/package/agent-coord-mcp)
(pinned in `package.json`, vendored through `node_modules/`). This repository is the
distribution around it: the CLI, hooks, chat server, tools, skill templates, and identity
registry that make a multi-agent workspace work out of the box.

> **Status note.** The project as it stands is primarily vibe coded — assembled and iterated
> by the agent team that uses it, verified end-to-end but not yet reviewed line by line. A
> proper rewrite and review pass is intended; treat the code as functional scaffolding, not a
> finished design.

## Layout

| Path | Contents |
| --- | --- |
| `bin/coord` | The one CLI: `init`, `seat add`, `chat start|stop|status|restart`, `update`, `identity add`. |
| `core/chat/` | Team chat server + web UI (`server.mjs`, `public/`), recess logic (`recess.mjs`, `recess-cli.mjs`). |
| `core/hooks/` | Lifecycle hooks (`session-start`, `prompt-context`, `keep-alive`) driven by `.devin/coord.json`. |
| `core/skills/` | Generic `team` and `recess` skills, rendered per-project at `coord init`. |
| `core/tools/` | `coord-web`, `coord-chat`, `coord-recess` — shell entry points used by agents and the human. |
| `agents/` | Global identity registry: `<name>/identity.md` (display name, personality) + `memory.md` (persistent notes). |
| `templates/` | `COORDINATION.md`, `ORGANICS.md`, `coord.json`, `hooks.v1.json`, `mcp_config.json`, `AGENTS-block.md`. |
| `ports.json` | Chat UI port registry; `coord init` allocates the lowest free port. |

## Quick start

```sh
# Wire a workspace for a three-seat team
node ~/Repos/agent-coord/bin/coord init /path/to/workspace --seats a:rose,b:patrick,c:iris

# Start the human-facing chat UI
node ~/Repos/agent-coord/bin/coord chat start /path/to/workspace
```

`init` writes `.devin/coord.json` (project, seats, room, port), per-seat MCP entries in
`.devin/mcp_config.json`, symlinks `.devin/chat` and `.devin/hooks` into this repo, renders the
`<project>-team` and `<project>-recess` skills, copies `COORDINATION.md` and `ORGANICS.md`
(never clobbered), and appends a managed block to the workspace's `AGENTS.md`.

```sh
node bin/coord seat add <workspace> <seat>:<identity>   # add a seat later
node bin/coord update <workspace>                      # re-verify links and rendered skills
node bin/coord identity add <name> --display "Name"    # scaffold a new global identity
```

## How it fits together

- **The bus is files.** `.devin/agent-coord/state/` holds JSONL rooms, per-seat inboxes, cursors,
  and the agent registry. Every seat's `agent-coord-<seat>` MCP server reads and writes it; the
  chat server tails the same files and pushes them to the browser over SSE.
- **Seats and identities are separate.** A seat is a workspace slot (`a`, `jobs-b`); an identity
  is a person (`rose`, `iris`) with a display name, personality, and memory that persist across
  workspaces. `coord.json`'s `seats` map binds them; `agents/<name>/` holds the person.
- **Hooks read, never write the bus.** Session start injects team context, identity, and recent
  room traffic; prompt submit surfaces what arrived while the model was busy; the stop hook
  refuses idle turns until a stand-down or recess marker releases it.
- **The human is a seat too.** The chat UI registers the human on the bus, posts to rooms and
  DMs, pings seats with `@name` / `@displayName` / `#room`, and can call a recess or release the
  team with stand-down — all on the same bus the agents use.

## Documentation

- `templates/COORDINATION.md` — the per-workspace working agreement (lane ownership, shared-tree rules).
- `templates/ORGANICS.md` — team personality defaults, editable per workspace.
- `agents/README.md` — the identity registry format.
- `templates/AGENTS-block.md` — the managed block appended to a workspace's `AGENTS.md`.
