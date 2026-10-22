# Autonom Daemon

[![License](https://img.shields.io/badge/License-AGPL--3.0-blue)](LICENSE.txt)
[![CI](https://github.com/autonom-ai/daemon/actions/workflows/ci.yml/badge.svg)](https://github.com/autonom-ai/daemon/actions/workflows/ci.yml)

> [!NOTE]
>
> Autonom Daemon currently targets and is validated on Linux only. macOS and Windows are not supported.

Autonom Daemon is a native D service and CLI that supervises local Devin CLI sessions as long-lived, addressable, and policy-governed agents. It owns the session and profile store, rooms and direct messages, policy screening, schedules and wakes, the loopback HTTP API, the ACP stdio host, the coordination MCP proxy, and the Devin CLI lifecycle hooks.

Sessions run the real Devin CLI over ACP. Autonom supervises them and records their coordination state without replacing the underlying model or CLI runtime. The Desktop launcher that renders the Command Center sidebar in Devin Desktop lives in [autonom-ai/devin](https://github.com/autonom-ai/devin) and reaches this service through the `autonom` command.

## Domain Model

| Concept | Purpose |
| --- | --- |
| **Session** | One Devin CLI conversation with a durable identifier, workspace, model, and transcript supervised over ACP. |
| **Profile** | A named identity that outlives individual sessions and owns its inbox, pending events, and schedules. `human` is reserved for the operator. |
| **Room** | A named multi-profile stream with an owner, optional administrators, and optional membership restrictions. |
| **Message** | A durable room post or direct message ordered per stream and read through per-profile cursors. |
| **Ping** | An urgent notice that interrupts named profiles on their next tool call or wakes them when offline. |
| **Event** | Unread activity queued for a profile: pings, room posts, direct messages, and scheduled clock wakes. |
| **Schedule** | A durable wake instruction (`ping`, `dm`, `room`, or `clock`) delivered as an event when due. |
| **Policy rule** | A workspace-scoped `allow`, `deny`, or `screen` decision evaluated on `PreToolUse` before a tool executes. |
| **Hook** | A Devin CLI lifecycle callback registered globally so policy evaluation, event reminders, and session identity reach the daemon. |
| **Call** | One bounded child process owned by the daemon, tracked in memory, and persisted to the execution index. |

## Requirements

| Requirement | Purpose |
| --- | --- |
| `ldc2` and [DUB](https://dub.pm) | Building the `autonom` executable and running the D test suites. |
| Python 3 (standard library only) | Running the stdio MCP proxy, the hook forwarder, and the user-level installer. |

## Installation

Build the `autonom` executable as your normal user, then install it into your user directories:

```sh
dub build --compiler=ldc2 --config=daemon
python3 install.py --no-build
```

Omitting `--no-build` runs the DUB build step automatically before copying files:

```sh
python3 install.py
```

The installer copies the binary and runtime helpers (`source/mcp` and `templates`) into `$XDG_DATA_HOME/autonom` (default `~/.local/share/autonom`), symlinks `~/.local/bin/autonom`, and creates `~/.config/autonom/config.yml` from `templates/config.yml` with mode `0600` only when no configuration file exists. It never overwrites existing configuration, `.env` secrets, session data, or logs, and it does not require `sudo`.

Inspect or remove the user-level installation with:

```sh
python3 install.py --check
python3 install.py --uninstall
```

## Quick Start

Ensure the daemon is listening on its configured loopback port and inspect its health:

```sh
autonom daemon --ensure
```

If `~/.config/autonom/config.yml` does not exist yet, `autonom daemon --ensure` creates it from the packaged template before starting the daemon.

| Command | Purpose |
| --- | --- |
| `autonom daemon` | Run the HTTP daemon in the foreground. |
| `autonom daemon --ensure` | Ensure the configured daemon is listening on loopback, then print its health JSON. |
| `autonom acp --config PATH [--devin COMMAND]` | Serve ACP over stdio for Devin Desktop, starting an in-process daemon if none is listening. |
| `autonom mcp` | Run the `autonom-coord` MCP server over stdio. |
| `autonom hook --event EVENT` | Forward a Devin CLI lifecycle hook payload to the daemon over loopback HTTP. |
| `autonom --help`, `autonom --version` | Print command usage or the version string. |

## Configuration

The daemon reads `~/.config/autonom/config.yml`, or the path supplied by `--config` or `AUTONOM_CONFIG`. `devinCommand` and `router` are required:

```yaml
dataDir: ~/.local/share/autonom
devinCommand: devin
executionTimeout: 30m
compactOnResume: false
offlineStartAfter: 1h
offlineCompactAfter: 1h
router:
  type: openrouter
  key: "OPENROUTER_API_KEY"
  url: https://openrouter.ai
  name: OpenRouter
  referer: ""
  title: ""
```

The `router` block is used through [Intuit](https://github.com/cetio/intuit) to evaluate `screen` rules in a workspace's `.devin/policy.yml`. When `router.key` is an uppercase identifier such as `OPENROUTER_API_KEY`, the daemon resolves the secret from the `.env` file beside `config.yml` or from the process environment so credentials stay out of configuration files.

## Modules

| Module or path | Primary responsibilities |
| --- | --- |
| `app` (`source/app.d`) | CLI command dispatch (`daemon`, `acp`, `mcp`, `hook`) and Serverino loop startup. |
| `daemon.api` | Single-worker assembly of the domain stores, scheduler, bridge, and policy engine. |
| `daemon.config` | YAML configuration parsing, duration/byte-size readers, secret resolution, and Intuit router construction. |
| `daemon.agent` | `Profile` and `ProfileStore` ownership, durable session assignments, and `/api/profiles` endpoints. |
| `daemon.coord` | `Room`, `RoomStore`, `Stream`, `Bus`, per-profile cursors, and `/api/rooms` and `/api/messages` endpoints. |
| `daemon.events` | `Event`, `Schedule`, `Scheduler`, wake delivery, session adoption, and `/api/events` and `/api/schedules` endpoints. |
| `daemon.policy` | `.devin/policy.yml` rule compilation, Intuit predicate screening, and `/api/policy` endpoints. |
| `daemon.hooks` | Authenticated Devin CLI hook handlers (`/api/hooks/*`), policy enforcement on `PreToolUse`, and unread event reminders. |
| `daemon.acp` | Stdio ACP host bridging Devin Desktop to daemon-managed sessions. |
| `daemon.interop` | Devin CLI process management, ACP client framing and routing, read-only CLI SQLite inspection, and capability tokens. |
| `source/mcp/` | Stdio JSON-RPC MCP proxy (`autonom-coord`) and `--ensure` loopback bootstrapper. |
| `templates/` | Packaged `config.yml`, `policy.yml`, `hooks.v1.json`, and `hook.py` runtime assets. |

## Development Documentation

- [Testing](TESTING.md)
- [Contributing](CONTRIBUTING.md)
- [Third-Party Notices](NOTICE)

## Roadmap

- [x] Single-worker HTTP daemon and capability-scoped session control
- [x] Durable profiles, rooms, direct messages, pings, and cursor-tracked streams
- [x] Scheduled wakes (`ping`, `dm`, `room`, `clock`) and interrupted-call reconciliation
- [x] Workspace `.devin/policy.yml` screening via Intuit and fail-closed `PreToolUse` hooks
- [x] Unified `autonom` CLI (`daemon`, `acp`, `mcp`, `hook`) and user-level installer
- [ ] Unified SQLite domain store (`autonom.db`) replacing file-backed JSON/JSONL streams
- [ ] Automated GitHub Pages API documentation generated from Ddoc and Python docstrings
- [ ] macOS and Windows platform validation

## License

Autonom Daemon is licensed under [AGPL-3.0](LICENSE.txt). Third-party attributions for DUB dependencies are recorded in [NOTICE](NOTICE).
