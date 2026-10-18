# Documentation

Autonom is three processes that share one domain model. The daemon owns state, the launcher injects UI, and the MCP proxy gives the model the same vocabulary the operator sees.

- [Sessions](SESSIONS.md) — what a session is, how Autonom and native catalogs coexist, profile assignment, ACP supervision, permissions, compaction, and transcripts.
- [Coordination](COORDINATION.md) — profiles, rooms, messages, pings, events, schedules, the MCP tools, and the on-disk layout.
- [Policy and hooks](POLICY.md) — the workspace policy file, screening, the Devin CLI hooks the daemon installs, and how a tool call is stopped.
- [Daemon architecture](DAEMON.md) — worker ownership, configuration, HTTP surface, bounds, and deployment.
- [Command Center](COMMAND_CENTER.md) — the Devin Desktop adapter, the sidebar contract, the native pin, and the live validation procedure.

## Subsystems

| Subsystem | Source | Responsibility |
| --- | --- | --- |
| Daemon | `source/daemon`, `source/app.d` | One persistent HTTP worker that owns all mutable state. |
| ACP entrypoint | `source/acp.d` | The stdio connector Devin Desktop launches. |
| MCP proxy | `source/mcp/server.py` | Bridges coordination tools between the model and the daemon. |
| Hook entrypoint | `source/daemon/interop/devin/hook.py` | Forwards Devin CLI lifecycle events to the daemon. |
| Launcher | `devin/launcher` | Starts and instruments Devin Desktop, and owns the Command Center. |
| Installer | `devin/install.py` | Transactional installation beside the Desktop directory. |
| Sidebar definition | `assets/` | Sections, items, pages, actions, icons, and styles for the Command Center. |

## Vocabulary

Terms used across these documents:

| Term | Meaning |
| --- | --- |
| **Managed session** | A session Autonom started and supervises, with a live ACP connection and a run token. |
| **Native session** | A Devin session Autonom only reads from the Devin catalog. Discovery never grants control over it. |
| **Workspace** | The directory a session runs in. Policy, membership, and room scope resolve against it. |
| **Call** | One owned child process: an ACP session, an execution, or a wake. |
| **Capability** | A scoped credential: operator, per-session, or per-run. Pages never receive one. |
| **Surface** | The native Devin Desktop page currently mounted by the Command Center. |
| **Event** | Unread work delivered to a profile. Events are cleared by reading them. |

## Conventions

Configuration keys, module paths, and HTTP routes appear in `code` formatting and match the source exactly. Statements about what Autonom does not do are deliberate: discovery does not grant control, hooks fail closed, and the launcher never rewrites vendor bundles.