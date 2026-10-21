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
python3 tests/install.py
```

The D unit suite launches the production daemon on loopback port 18080 and must run serially. The MCP suite drives the real daemon over HTTP and the real command over stdio. The installer suite uses only temporary prefixes.

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

The conventions below are the working style guide for this repository. They describe how to write and review code; they are not permission to reformat unrelated files. Preserve protocol behavior, ownership, and safety invariants while improving style. Do not create abstractions, compatibility layers, or file splits solely to satisfy a checklist.

### Shared

- Prefer direct, imperative, domain-shaped code. Keep mutable state with its owner. Add a type, helper, layer, or interface only when it names a real operation or boundary, clarifies ownership, or protects an invariant.
- Make control flow, data flow, and lifetime visible. Keep a temporary when it explains a transition, supports cleanup, or is reused.
- Use meaningful names that are brief in context. Avoid cryptic abbreviations and names that disguise the real operation.
- Comments explain non-obvious invariants, protocol constraints, and safety boundaries. Do not narrate ordinary statements.
- Prefer real domain types and real behavior in tests. A simulated peer is not evidence of compatibility with an installed product.

### D

- Types, classes, structs, interfaces, and exceptions use `PascalCase`. Functions, methods, fields, parameters, locals, and constants use `camelCase`. Enum members use `PascalCase` even when their wire values do not.
- Name a constructed or accumulated return value `ret`. Return a direct expression directly.
- Use `struct` for value records, options, and results. Use `class` for identity-bearing services and shared mutable owners.
- Give ordinary locals explicit types. Use inference only for unnameable results.
- Group imports as project modules, external dependencies, then runtime modules, separated by one blank line. Within the runtime group, `core.*` comes before `std.*`. Keep imports at module scope.
- Use four-space indentation and Allman braces. Omit braces for a single-line scoped statement. Write an empty block as `{ }`.
- Use `scope(exit)` and `scope(failure)` without a space. Do not write `while (true)` or `for (;;)`.
- Put no spaces around `~`, `..`, or `cast(Type)value`. Aim for lines near or below 120 columns.
- Use `///` for public API contracts and `//` for implementation rationale.
- Name tests for behavior and use `@Name`, `@ShouldFailWith`, and scoped cleanup.
- Aim for roughly 200 lines per file and stay under 400. Split distinct responsibilities before a file approaches the ceiling.

### Python

- Follow Python conventions: four-space indentation, `snake_case` functions and values, `PascalCase` types, and uppercase module constants.
- Keep subprocesses, output, credentials, environment forwarding, and exception behavior bounded and intentional. Security-sensitive hooks fail closed when authentication or validation fails.

### TypeScript

The launcher lives in [autonom-ai/devin](https://github.com/autonom-ai/devin) and keeps the same conventions: four-space indentation, Allman braces, double-quoted strings, semicolons, `camelCase` values, and `PascalCase` types.

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
