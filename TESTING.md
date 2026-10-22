# Testing

The repository has D unit and integration tests, Python MCP proxy tests, CLI command surface tests, and user-level installer tests. The D suites use [unit-threaded](https://github.com/atilaneves/unit-threaded) and the generated runner at `bin/ut.d`.

- **D unit tests** cover configuration parsing, secret resolution, profiles, rooms, streams, cursors, events, schedules, wakes, policy rules, ACP framing, read-only CLI SQLite queries, and loopback HTTP endpoints against a real daemon instance on port `18080`.
- **CLI integration tests** (`--d-version=devin`) exercise session catalog and metadata interoperability against an installed `devin` CLI with isolated XDG directories and no model credentials.
- **Python suites** cover the `autonom-coord` stdio MCP server, lifecycle hook forwarding, the `autonom` CLI subcommands, and `install.py` prefix installations.

## Prerequisites

Install [DUB](https://dub.pm), `ldc2`, and Python 3. Running the real CLI integration suite additionally requires the `devin` executable on `PATH`:

| Suite | Required tools |
| --- | --- |
| Offline D, MCP, command, and installer suites | `dub`, `ldc2`, `python3` |
| CLI integration (`--d-version=devin`) | `dub`, `ldc2`, `devin` |

Add `--skip-registry=all` to DUB commands when dependencies are already cached locally and network access is unavailable.

## Running Tests

> [!IMPORTANT]
>
> The D unit suite launches the production daemon on loopback port `18080` and must be run serially. Do not run multiple `dub run --config=unit` processes concurrently.

| Command | Meaning |
| --- | --- |
| `dub build --compiler=ldc2 --config=daemon` | Builds `bin/autonom` (also run automatically as a pre-build step of the `unit` configuration). |
| `dub run --compiler=ldc2 --config=unit --build=unittest` | Runs all offline D unit and HTTP daemon tests. |
| `dub run --compiler=ldc2 --config=unit --build=unittest --d-version=devin` | Runs the D suite plus real `devin` CLI integration tests. |
| `python3 source/mcp/tests.py` | Runs the stdio MCP proxy and hook integration tests against a temporary daemon instance. |
| `python3 tests/command.py` | Runs the `autonom` CLI surface smoke tests (`--help`, `--version`, `mcp`, `hook`, `daemon --ensure`). |
| `python3 tests/install.py` | Runs the user-level installer, `--check`, and `--uninstall` tests in temporary prefixes. |

Run all offline verification suites before opening a pull request:

```sh
dub build --compiler=ldc2 --config=daemon
dub run --compiler=ldc2 --config=unit --build=unittest
python3 source/mcp/tests.py
python3 tests/command.py
python3 tests/install.py
```

Pass a `unit-threaded` test name or substring after `--` to filter the D suite:

```sh
dub run --compiler=ldc2 --config=unit --build=unittest -- "Daemon coordinates rooms and messages"
dub run --compiler=ldc2 --config=unit --build=unittest -- "resolveSecret"
```

## Test Layout

| Path | Purpose |
| --- | --- |
| `source/tests/config/` | YAML configuration parsing, duration/byte-size validation, and `.env` secret resolution tests. |
| `source/tests/profile.d` | `Profile` and `ProfileStore` lifecycle, persistence, and session binding tests. |
| `source/tests/coord/` | Room creation, membership, message streams, per-profile cursors, and retention bounds. |
| `source/tests/events/` | Event queueing, schedule firing, wake delivery, compaction on resume, and interrupted-call recovery. |
| `source/tests/policy/` | `.devin/policy.yml` rule compilation, context redaction, and Intuit predicate screening tests. |
| `source/tests/interop/` | ACP JSON-RPC framing, client lifecycle, read-only CLI SQLite queries, hooks registration, and MCP tokens. |
| `source/tests/http/` | End-to-end loopback HTTP API tests (`server`, `access`, `client`, `coord`, `desktop`, `events`, `permissions`, `policy`, `sessions`, `wakes`). |
| `source/tests/integration/` | Partition and real `devin` CLI integration suites (`version(devin)`). |
| `source/tests/fakeagent.py` | Deterministic fake ACP agent used by bridge, wake, and HTTP tests. |
| `source/mcp/tests/` | Python `unittest` suites for `autonom-coord` (`coordination.py`, `hooks.py`, `protocol.py`, `support.py`). |
| `tests/command.py` | Subcommand and `daemon --ensure` bootstrap tests for `bin/autonom`. |
| `tests/install.py` | Prefix installation, symlink guard, config preservation, and uninstall tests for `install.py`. |
| `bin/ut.d` | Generated `unit-threaded` entry point. Do not edit it manually. |

## Writing Tests

Name D tests with `@Name` so individual cases can be filtered from the command line, and use `@ShouldFailWith` for expected exceptions. Clean up temporary directories and child processes with `scope(exit)`.

```d
@Name("resolveSecret reads a named key from the beside .env file")
unittest
{
    SecretFixture fixture = SecretFixture.create();
    scope(exit)
        fixture.dispose();

    resolveSecret("OPENROUTER_API_KEY", fixture.root).should == "sk-or-v1-actual";
}
```

Keep tests independent of the operator's real `~/.config/autonom`, `~/.local/share/autonom`, and `~/.config/devin` directories by constructing isolated temporary roots or overriding `HOME` and the `XDG_*` environment variables.

## CI/CD

The [CI workflow](.github/workflows/ci.yml) runs on pushes to `main` and on pull requests using `ubuntu-latest` and `ldc-latest`. It builds `bin/autonom` and executes the D unit suite, the MCP suite, the CLI command suite, and the installer suite in sequence.
