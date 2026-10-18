# Autonom

[![License](https://img.shields.io/badge/License-AGPL--3-blue)](LICENSE.txt)
[![CI](https://github.com/cetio/autonom/actions/workflows/ci.yml/badge.svg)](https://github.com/cetio/autonom/actions/workflows/ci.yml)

Autonom turns Devin CLI sessions into long-lived agents that can be addressed, scheduled, and governed. A D daemon owns sessions, profiles, rooms, messaging, policy, and schedules; a Node launcher injects a Command Center sidebar into Devin Desktop; a stdio MCP proxy exposes coordination tools to the model itself. Sessions run the real Devin CLI over ACP — Autonom supervises them, it does not replace the model.

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
| **Command Center** | The Autonom sidebar injected into Devin Desktop. It lists rooms, profiles, and pages, and forwards navigation to the native surface controller. |

See [Documentation](docs/README.md) for the contracts behind each concept.

## Requirements

| Requirement | Used by |
| --- | --- |
| D compiler `ldc2` and DUB | Daemon and relay builds. |
| Node.js 22+ | Launcher build, tests, and the Command Center bundle. |
| Python 3 (standard library only) | MCP proxy, hook entrypoint, and installer. |
| Devin Desktop 1.126.0 | Command Center target. The build is pinned and the launcher refuses any other. |

## Installation

Build and test as your normal user, then install with the permissions required by the Desktop directory:

```sh
npm --prefix devin ci
npm --prefix devin run check
npm --prefix devin test
sudo python3 devin/install.py --no-build
```

The installer replaces only the `bin/devin-desktop` CLI shim, preserving the original byte-for-byte, and copies the launcher bundle, runtime assets, daemon binaries, MCP proxy, and hook entrypoint beside the Desktop installation. The Electron binary, workbench bundles, `product.json`, and profile data are untouched.

Quit Desktop once, then launch it normally:

```sh
devin-desktop
```

Your existing profile and login remain in use. `devin-desktop --debug` starts the same launcher with a loopback CDP port for development; the default transport is a private pipe that never listens on a port.

Check the installation, or roll it back:

```sh
python3 devin/install.py --check
sudo python3 devin/install.py --uninstall
```

The installer references this checkout, so keep it in place. Desktop upgrades replace the patch and require reinstallation after rechecking compatibility. Windows and macOS installation have not been validated.

## Configuration

The daemon reads `~/.config/autonom/config.yml`. `dataDir`, `devinCommand`, and `router` are required:

```yaml
dataDir: ~/.local/share/autonom
devinCommand: devin
compactOnResume: false
executionTimeout: 30m
offlineStartAfter: 1h
offlineCompactAfter: 1h
router:
  type: openrouter
  key: ""
  url: https://openrouter.ai
  name: OpenRouter
```

The router is used only for policy screening. Keep its key out of version control. Sessions, rooms, inboxes, and execution history live under `dataDir`.

The Command Center reads `~/.config/autonom/launcher.yml` for its port and configuration paths, and the sidebar definition lives in `assets/ui.yml`.

## Documentation

- [Documentation index](docs/README.md)
- [Sessions](docs/SESSIONS.md)
- [Coordination](docs/COORDINATION.md)
- [Policy and hooks](docs/POLICY.md)
- [Daemon architecture](docs/DAEMON.md)
- [Launcher and native patches](docs/launcher/README.md)
- [Command Center](docs/launcher/patches/COMMAND_CENTER.md)

## Development

```sh
dub build --compiler=ldc2 --config=daemon
dub build --compiler=ldc2 --config=relay
dub run --compiler=ldc2 --config=unit --build=unittest
python3 source/mcp/tests.py
npm --prefix devin ci
npm --prefix devin run check
npm --prefix devin test
```

Add `--skip-registry=all` to DUB commands when dependencies are cached and network access is unavailable. The unit suite launches the production daemon on loopback port 18080 and must run serially. Real CLI integration adds `--d-version=devin` and needs no model credentials.

## License

Autonom is licensed under [AGPL-3.0](LICENSE.txt). Bundled icon attributions are recorded in [assets/ATTRIBUTION.md](assets/ATTRIBUTION.md).