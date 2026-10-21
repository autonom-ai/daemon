# Command reference

`autonom` is the only interface other repositories use. The Desktop launcher, the Devin CLI hooks, and the MCP registration all call this command by name.

```sh
autonom <command> [options]
```

## Commands

| Command | Purpose |
| --- | --- |
| `autonom daemon` | Run the HTTP daemon in the foreground until it is stopped. |
| `autonom daemon --ensure` | Ensure the configured daemon is listening, then print its health. |
| `autonom acp --config PATH [--devin COMMAND]` | Serve ACP over stdio for Devin Desktop. |
| `autonom mcp` | Run the coordination MCP proxy over stdio. |
| `autonom hook --event EVENT` | Forward a Devin CLI hook event to the daemon. |
| `autonom --help` | Print the usage. |
| `autonom --version` | Print the version. |

Running `autonom` without a command starts the daemon, and a binary named after the legacy connector serves ACP. That keeps an installation working while the launcher moves to the new registration.

## Options

| Option | Meaning |
| --- | --- |
| `--config PATH`, `-c` | Configuration file for the daemon and the ACP host. |
| `--port PORT`, `-p` | HTTP API port. |
| `--devin COMMAND` | Devin CLI executable or path. |
| `--ensure` | Ensure the configured daemon is listening instead of serving in the foreground. |
| `--event EVENT` | Hook event name. |

## Environment

| Variable | Meaning |
| --- | --- |
| `AUTONOM_CONFIG` | Configuration file. `--config` wins. |
| `AUTONOM_PORT` | HTTP API port. `--port` wins. |
| `AUTONOM_DEVIN` | Devin CLI executable or path. `--devin` wins. |
| `AUTONOM_DATA_DIR` | Data root of the running session. |
| `AUTONOM_RUN_TOKEN` | Per-run capability the daemon issues for one call. |
| `AUTONOM_MCP_TOKEN` | Per-session capability the daemon issues for one session. |
| `AUTONOM_CLIENT_TOKEN` | Operator capability. |

## Daemon

`autonom daemon` owns the HTTP API and the whole domain on one persistent worker. The listener binds loopback only. `GET /api/health` reports liveness, the process identifiers, the configuration path, and the control token path; it answers `stopping` with 503 while the worker winds down.

`autonom daemon --ensure` starts the daemon when nothing is listening on the configured port and waits for it to answer. It prints the health document on success and reports the log path on failure.

## ACP host

`autonom acp` speaks newline-delimited JSON-RPC over stdio with the Devin CLI. It starts a daemon when none is listening and shuts down the one it started when ACP ends. Inherited `ACP_BACKEND` and related variables are removed from the child environment.

## MCP proxy

`autonom mcp` speaks the Model Context Protocol over stdio and proxies tool calls to the daemon's HTTP API. Managed sessions receive an `AUTONOM_MCP_TOKEN` in their environment, and the daemon resolves it to the owning session, so tool arguments never carry a session ID. Unmanaged processes advertise no tools. A tool call starts the daemon when it is not already listening.

## Hook

`autonom hook --event EVENT` forwards one Devin CLI lifecycle event to the daemon over loopback HTTP, authenticating with the run token (`x-autonom-run`) or the session's MCP capability (`x-autonom-mcp`). The event must match the registered hook. When authentication or validation fails, the sensitive events — `PreToolUse` and `PermissionRequest` — fail closed and block the call; the others return an empty decision.
