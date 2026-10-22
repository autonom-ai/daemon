# Autonom Daemon

[![License](https://img.shields.io/badge/License-AGPL--3-blue)](LICENSE.txt)
[![CI](https://github.com/autonom-ai/daemon/actions/workflows/ci.yml/badge.svg)](https://github.com/autonom-ai/daemon/actions/workflows/ci.yml)

Autonom turns Devin CLI sessions into long-lived agents that can be addressed, scheduled, and governed. This repository owns the daemon: the session and profile store, rooms and messages, policy screening, schedules and wakes, the HTTP API, the ACP host, the MCP proxy, and the Devin CLI hooks. Sessions run the real Devin CLI over ACP — Autonom supervises them, it does not replace the model. The Desktop launcher that renders the Command Center lives in [autonom-ai/devin](https://github.com/autonom-ai/devin) and reaches this daemon through the `autonom` command.

## Concepts

The domain is small and every noun below is owned by the daemon:

| Concept | What it is |
| --- | --- |
| **Session** | One Devin CLI conversation with a durable identity, workspace, model, and transcript. Autonom supervises it over ACP and stores its state. |
| **Profile** | A named identity that a session registers as. A profile outlives the sessions bound to it and owns its inbox, events, and schedules. `human` is reserved for the operator. |
| **Room** | A named workspace that several profiles can read and post into. A room has an owner, optional admins, and an optional membership restriction. |
| **Message** | A room post or a direct message. Messages are durable, ordered per stream, and read through cursors. |
| **Ping** | An urgent notice that interrupts named profiles on their next tool call, or wakes them if they are offline. |
| **Event** | Something a profile has not read yet: pings, room and DM activity, and clock wakes. Reading events clears them. |
| **Schedule** | A durable wake instruction — `ping`, `dm`, `room`, or `clock` — that the daemon delivers as an event when it fires. |
| **Policy rule** | A workspace-scoped `allow`, `deny`, or `screen` decision evaluated on every tool call, before the tool runs. |
| **Hook** | A Devin CLI lifecycle callback that the daemon registers globally so policy, context, and session identity reach it. |
| **Call** | One asynchronous child process the daemon owns. Calls are bounded, tracked in memory, and persisted to an execution index. |

See [Documentation](docs/README.md) for the contracts behind each concept.

## Requirements

| Requirement | Used by |
| --- | --- |
| D compiler `ldc2` and DUB | Building the `autonom` command. |
| Python 3 (standard library only) | The MCP proxy, the hook entrypoint, and the installer. |

The daemon is Linux-focused. macOS and Windows are not validated.

## Installation

Clone with the shared assets, or initialize them in an existing checkout:

```sh
git clone --recurse-submodules git@github.com:autonom-ai/daemon.git
git submodule update --init --recursive
```

The `core/` submodule supplies the configuration template and the ACP validation skill. Without it, `templates/config.yml` and `.devin/skills/acp-validation` are dangling symlinks.

Build as your normal user, then install the command for your account:

```sh
dub build --compiler=ldc2 --config=daemon
python3 install.py
```

The installer puts the command in `$XDG_DATA_HOME/autonom` (default `~/.local/share/autonom`), exposes it as `~/.local/bin/autonom`, and creates `~/.config/autonom/config.yml` only when it is missing. It never rewrites an existing configuration, `.env`, session, or log, and it needs no `sudo`. When `~/.local/bin` is not on `PATH`, the installer says so and prints the line to add.

Check the installation, or remove it again:

```sh
python3 install.py --check
python3 install.py --uninstall
```

Uninstalling removes the command and the runtime files it installed. Configuration, `.env`, data, sessions, and logs stay in place.

## Commands

The command surface is the only interface other repositories use:

| Command | Purpose |
| --- | --- |
| `autonom daemon` | Run the HTTP daemon in the foreground. |
| `autonom daemon --ensure` | Ensure the configured daemon is listening, then report its health. |
| `autonom acp --config PATH [--devin COMMAND]` | Serve ACP over stdio for Devin Desktop. |
| `autonom mcp` | Run the coordination MCP proxy over stdio. |
| `autonom hook --event EVENT` | Forward a Devin CLI hook event to the daemon. |
| `autonom --help`, `autonom --version` | Print the usage or the version. |

See [the command reference](docs/CLI.md) for the options and the environment each command honors.

## Configuration

The daemon reads `~/.config/autonom/config.yml`, or the path in `--config` / `AUTONOM_CONFIG`. `dataDir`, `devinCommand`, and `router` are required:

```yaml
dataDir: ~/.local/share/autonom
devinCommand: devin
compactOnResume: false
executionTimeout: 30m
offlineStartAfter: 1h
offlineCompactAfter: 1h
router:
  type: openrouter
  key: "OPENROUTER_API_KEY"
  url: https://openrouter.ai
  name: OpenRouter
```

The router is used only for policy screening. An uppercase identifier such as `OPENROUTER_API_KEY` is a reference: the daemon reads the real value from the `.env` beside the configuration file. Keep it out of version control. Sessions, rooms, inboxes, and execution history live under `dataDir`.

## Documentation

- [Documentation index](docs/README.md)
- [Daemon architecture](docs/ARCHITECTURE.md)
- [Sessions](docs/SESSIONS.md)
- [Coordination](docs/COORDINATION.md)
- [Policy and hooks](docs/POLICY.md)
- [Installation](docs/INSTALLATION.md)
- [Command reference](docs/CLI.md)
- [Development](docs/DEVELOPMENT.md)

## Development

```sh
dub build --compiler=ldc2 --config=daemon
dub run --compiler=ldc2 --config=unit --build=unittest
python3 source/mcp/tests.py
python3 tests/command.py
python3 tests/install.py
```

Add `--skip-registry=all` to DUB commands when dependencies are cached and network access is unavailable. The unit suite launches the production daemon on loopback port 18080 and must run serially. Real CLI integration adds `--d-version=devin` and needs no model credentials.

## License

Autonom is licensed under [AGPL-3.0](LICENSE.txt).
