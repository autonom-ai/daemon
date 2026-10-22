# Development

## Build

```sh
dub build --compiler=ldc2 --config=daemon
```

The configuration produces `bin/autonom`, the single command that dispatches the daemon, the ACP host, the MCP proxy, and the hook. Add `--skip-registry=all` when the dependencies are cached and the network is unavailable.

## Tests

```sh
dub run --compiler=ldc2 --config=unit --build=unittest
python3 source/mcp/tests.py
python3 tests/command.py
python3 tests/install.py
```

The D unit suite launches the production daemon on loopback port 18080 and must run serially. The MCP suite drives the real daemon over HTTP and the real command over stdio. The command suite covers the `autonom` surface — help, version, the MCP proxy, the hook, and `daemon --ensure`. The installer suite uses only temporary prefixes.

Real CLI integration establishes the catalog and metadata contract against an installed Devin CLI:

```sh
dub run --compiler=ldc2 --config=unit --build=unittest --d-version=devin
```

It isolates the XDG state and needs no model credentials.

| Path | Purpose |
| --- | --- |
| `source/daemon/` | The daemon domain: agents, coordination, events, policy, hooks, interop. |
| `source/app.d` | The command dispatcher. |
| `source/mcp/` | The MCP proxy and its tests. |
| `source/tests/` | The D unit and integration suites. |
| `templates/` | The configuration, policy, and hook assets the daemon installs. |
| `tests/install.py` | The installer suite. |

## Style

The canonical shared conventions live in [`core/docs/CONVENTIONS.md`](../core/docs/CONVENTIONS.md) ([GitHub](https://github.com/autonom-ai/core/blob/main/docs/CONVENTIONS.md)). They cover the shared principles, D, TypeScript, and Python. This repository adds the layer boundaries below; [AGENTS.md](../AGENTS.md) adds its ownership and safety invariants.

## Layer boundaries

The daemon is layered, and the dependency direction never turns back:

| Layer | Modules | Owns |
| --- | --- | --- |
| Interop | `daemon.interop` | The Devin CLI, ACP, and the MCP registration. It reads state and never writes the domain. |
| Domain | `daemon.agent`, `daemon.coord`, `daemon.events`, `daemon.policy` | Profiles, rooms, messages, events, schedules, and policy rules. |
| API | `daemon.api`, `daemon.http` | The HTTP surface and the worker-owned assembly of the domain. |

Run the style checker before committing:

```sh
python3 .devin/skills/d-style/tools/check-style.py
```
