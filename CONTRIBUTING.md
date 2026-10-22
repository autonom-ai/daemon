# Contributing to Autonom Daemon

Thanks for contributing to Autonom Daemon. Keep changes focused, preserve the single-worker ownership and security invariants, follow the existing D and Python conventions, and include tests for behavioral changes.

## Reporting Issues

Search existing issues before opening a new one. Bug reports should include:

- Steps to reproduce and a minimal example or HTTP/CLI transcript when possible.
- Expected and actual behavior.
- Linux distribution, kernel version, `ldc2 --version`, `dub --version`, and `python3 --version`.
- Devin CLI version (`devin --version`) for session, ACP, or hook interoperability failures.
- Relevant daemon logs with all API keys, `.env` secrets, and capability tokens removed.

Feature requests should describe the use case, the affected domain module (`daemon.agent`, `daemon.coord`, `daemon.events`, `daemon.policy`, `daemon.hooks`, `daemon.interop`, or `source/mcp`), and how the change fits the `autonom` CLI contract.

## Development Setup

Install [DUB](https://dub.pm), `ldc2`, and Python 3. Build the command and verify the offline test suites:

```sh
dub build --compiler=ldc2 --config=daemon
dub run --compiler=ldc2 --config=unit --build=unittest
python3 source/mcp/tests.py
python3 tests/command.py
python3 tests/install.py
```

See [TESTING.md](TESTING.md) for test filtering, real CLI integration (`--d-version=devin`), and suite layout.

## Architecture and Style Conventions

- **Layer direction**: `daemon.interop` never imports `daemon.coord`, `daemon.events`, `daemon.policy`, or `daemon.acp`. Domain modules (`daemon.agent`, `daemon.coord`, `daemon.events`, `daemon.policy`, `daemon.hooks`) own state on the single Serverino worker thread.
- **Formatting and naming**: Use four-space indentation and Allman braces in D. Use `PascalCase` for types and enum members, and `camelCase` for functions, methods, fields, locals, and constants (`enum frameLimit = ...`). Name constructed return variables `ret`.
- **Imports**: Keep imports at module scope in three groups separated by one blank line: project modules, external DUB dependencies, then runtime modules (`core.*` before `std.*`).
- **Scope guards and loops**: Write `scope(exit)` and `scope(failure)` without a space before `(`. Avoid unbounded `while (true)` or `for (;;)` loops.
- **Documentation comments**: Document public types, endpoints, and functions with `///` Ddoc comments and Python modules/functions with docstrings so API documentation can be generated directly from source.
- **File size**: Aim for roughly 200 lines per file and stay under 400 lines.

## Review Checklist

Before opening a pull request:

1. Run the D unit suite, MCP tests, command tests, and installer tests listed in [TESTING.md](TESTING.md).
2. Confirm new tests fail without the fix when practical.
3. Verify that child processes, file reads, HTTP bodies, and capability checks remain bounded and fail closed.
4. Review the diff for build artifacts, unrelated formatting changes, and sensitive data.
5. Update `README.md` or `TESTING.md` when CLI flags, configuration fields, or HTTP routes change.

## License

By contributing, you agree that your contributions are licensed under the same [AGPL-3.0 license](LICENSE.txt) as Autonom Daemon.
