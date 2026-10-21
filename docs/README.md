# Documentation

The daemon is one process with three faces: the HTTP API, the ACP host that Devin Desktop launches, and the MCP proxy that gives the model the same vocabulary the operator sees. The Desktop launcher lives in [autonom-ai/devin](https://github.com/autonom-ai/devin) and reaches all three through the `autonom` command.

- [Daemon architecture](ARCHITECTURE.md) — worker ownership, configuration, HTTP surface, bounds, and deployment.
- [Sessions](SESSIONS.md) — what a session is, how Autonom and native catalogs coexist, profile assignment, ACP supervision, permissions, compaction, and transcripts.
- [Coordination](COORDINATION.md) — profiles, rooms, messages, pings, events, schedules, the MCP tools, and the on-disk layout.
- [Policy and hooks](POLICY.md) — the workspace policy file, screening, the Devin CLI hooks the daemon installs, and how a tool call is stopped.
- [Installation](INSTALLATION.md) — the user-level install, the installed layout, and what uninstall leaves alone.
- [Command reference](CLI.md) — the `autonom` command surface and the environment each command honors.
- [Development](DEVELOPMENT.md) — the build, the test suites, and the code style.

## Subsystems

| Subsystem | Source | Responsibility |
| --- | --- | --- |
| Daemon | `source/daemon`, `source/app.d` | One persistent HTTP worker that owns all mutable state. |
| ACP host | `source/daemon/acp.d` | The stdio connector Devin Desktop launches. |
| MCP proxy | `source/mcp/server.py` | Bridges coordination tools between the model and the daemon. |
| Hook entrypoint | `templates/hook.py` | Forwards Devin CLI lifecycle events to the daemon. |
| Command | `source/app.d` | Dispatches the daemon, the ACP host, the MCP proxy, and the hook. |
| Installer | `install.py` | Installs the command and its runtime for the current user. |
| Templates | `templates/` | The configuration, policy, and hook assets the daemon installs. |

## Vocabulary

Terms used across these documents:

| Term | Meaning |
| --- | --- |
| **Managed session** | A session Autonom started and supervises, with a live ACP connection and a run token. |
| **Native session** | A Devin session Autonom only reads from the Devin catalog. Discovery never grants control over it. |
| **Workspace** | The directory a session runs in. Policy, membership, and room scope resolve against it. |
| **Call** | One owned child process: an ACP session, an execution, or a wake. |
| **Capability** | A scoped credential: operator, per-session, or per-run. Pages never receive one. |
| **Event** | Unread work delivered to a profile. Events are cleared by reading them. |

## Conventions

Configuration keys, module paths, and HTTP routes appear in `code` formatting and match the source exactly. Statements about what Autonom does not do are deliberate: discovery does not grant control, hooks fail closed, and the daemon never rewrites a configuration it did not create.
