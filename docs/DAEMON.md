# Daemon architecture

The daemon is one persistent Serverino worker plus a small number of threads. Every mutable registry, stream, profile, and schedule lives on that worker. Threads exist to own child processes and to poke the loopback API; none of them mutate state directly.

| Thread | Owns |
| --- | --- |
| Main process | Process lifetime, argument parsing, and the ACP entrypoint when started as `autonom-acp`. |
| Worker | The HTTP API and all domain state. |
| Monitor threads | One per asynchronous call, owning its child or its request on an existing connection, plus call state. |
| Scheduler | Schedule evaluation and wake delivery. It requests loopback refreshes; it does not write state. |

`daemon.api` assembles the owners. HTTP handlers validate input and call into them; they do not keep state of their own. Human permission waits and child output never occupy the worker.

## Binaries

| Binary | Role |
| --- | --- |
| `autonom-daemon` | The HTTP API and domain owner. |
| `autonom-acp` | The stdio ACP connector Devin Desktop launches. It starts a daemon if none is listening and shuts down the one it started when ACP ends. |

Build both with `dub build --compiler=ldc2 --config=daemon` and `--config=relay`.

## Configuration

`~/.config/autonom/config.yml`, or the path in `--config` / `AUTONOM_CONFIG`. Unknown keys, duplicate keys, and wrong types are refused.

### Credentials

The configuration is not the place for a live credential. When a value is an
uppercase identifier — `OPENROUTER_API_KEY` — it is a reference, and the daemon
reads the real value from `.env` in the same directory as `config.yml`:

```yaml
router:
  type: openrouter
  key: OPENROUTER_API_KEY
  url: https://openrouter.ai
  name: OpenRouter
```

```sh
chmod 600 ~/.config/autonom/.env
```

The resolver accepts `NAME=value`, `export NAME=value`, single or double quotes
around a value, `#` comments on their own line, and `=` inside a value. Any other
value stays a literal, so an existing configuration keeps working, and a bare
identifier that no `.env` defines fails closed instead of being used as a key.

`.env` inherits the storage guards that protect the configuration file itself: a
symlink, a special file, or oversized content is refused. The resolved value is
never logged, written back into the configuration, or included in an error; a
failure names the variable and the file.

| Key | Default | Meaning |
| --- | --- | --- |
| `dataDir` | Directory of the config file | Root for profiles, rooms, sessions, executions, and catalogs. |
| `devinCommand` | Required | The Devin CLI executable or path. |
| `router` | Required | `type`, `key`, `url`, and `name` (plus optional `referer` and `title`) for policy screening. See [credentials](#credentials). |
| `sessionLockDir` | `$XDG_DATA_HOME/devin/cli/session_locks` | Native Devin lock directory. |
| `executionTimeout` | 30m | Hard limit on one call. |
| `compactOnResume` | `false` | Compact a session before resuming it. |
| `offlineStartAfter` | 1h | When an offline profile's wake is considered stale. |
| `offlineCompactAfter` | 1h | When an idle session compacts on its next resume. |
| `maxStreamBytes` | 4 MiB | Active stream size before rotation. |
| `maxStreamEntries` | 1000 | Active stream entries before rotation. |
| `callCapacity` | 128 | Settled call tickets held in memory. |
| `callSettleTimeout` | 5m | Age at which a settled call ticket is evicted. |
| `maxConcurrentCalls` | 8 | Concurrent calls, including prompts sharing a connection. |
| `pruneExecutionArtifacts` | `false` | Remove call logs after settling. |
| `allowDestructivePruning` | `false` | Permit pruning outside Autonom's own artifacts. |

Durations accept forms such as `30m` and `1h`. `sessionDatabase` is derived: it is `sessions.db` beside `sessionLockDir`. The managed catalog is always `<dataDir>/cli/sessions.db`.

## Capabilities

Three credentials, each scoped to one audience. They never appear in pages, webviews, or logs.

| Header | Capability | Grants |
| --- | --- | --- |
| `x-autonom-client` | Operator token in `<dataDir>/client.token` | Full operator access, used by the launcher and the Command Center bridge. |
| `x-autonom-run` | Per-run token | Exactly one running call. |
| `x-autonom-mcp` | Per-session MCP token in `<dataDir>/mcp/` | Exactly one session's coordination scope. |

`GET /api/health` and `/api/hooks/*` are reachable without the operator token; hooks authenticate themselves with a run or MCP credential and fail closed otherwise. Every other route resolves a caller profile from the request and refuses when none applies.

## HTTP surface

| Route | Purpose |
| --- | --- |
| `GET /api/health` | Liveness, PIDs, config path, and the control token path. |
| `GET|POST /api/sessions`, `/api/sessions/<id>`, `/api/sessions/remove` | Session listing, start, detail, and removal. |
| `/api/sessions/<id>/{resume,steer,stop,manage,log,transcript,permissions}` | Session control, transcripts, and permission settlement. |
| `/api/executions/<id>`, `/api/executions/<id>/{stop,transcript}` | Call outcomes and history. |
| `GET|POST /api/profiles`, `/api/profiles/<name>`, `/api/profiles/<name>/session` | Profiles and their session assignment. |
| `GET|POST /api/rooms`, `/api/rooms/<name>`, `/api/rooms/<name>/{membership,admins,messages}` | Rooms, membership, and posting. |
| `GET|POST /api/messages` | Direct messages and pings. |
| `GET|POST /api/events` | Unread events per profile. |
| `GET|POST /api/schedules`, `/api/schedules/<id>`, `POST /api/schedules/refresh` | Schedules and refresh. |
| `GET /api/policy`, `POST /api/policy/check` | Policy inspection and evaluation. |
| `POST /api/hooks/*` | The eight hook events. |
| `POST /api/acp/{admit,observe}`, `GET /api/mcp/session` | ACP admission, liveness observation, and MCP capability binding. |
| `GET /api/print` | Debug dump of worker state. |

## Calls and bounds

A call is one bounded asynchronous operation: an owned child process or a prompt on an existing ACP connection. Settled calls are evicted oldest-first; a running call is never evicted, and eviction persists metadata first.

| Bound | Value | Effect |
| --- | --- | --- |
| Execution index | 10,000 entries | Oldest entries drop out; historical IDs stop resolving. |
| Stream rotation | 4 MiB or 1,000 entries | One archive generation replaces the previous; the in-memory window survives. |
| Stream files | 2 per stream | Active plus archive. |
| Permissions | 64 outstanding, 16 MiB | Further backend requests are refused. |
| Frames | 16 MiB | A larger frame fails the connection. |
| Outgoing requests | 256 | Further correlation slots are refused. |

Rotation refuses to follow symlinks. Restart reconstruction reads the archive tail and the active log, so cursors stay valid.

## ACP and Desktop

`autonom-acp` speaks newline-delimited JSON-RPC over stdio with the Devin CLI. Routing between Desktop and the daemon rewrites the ID of a copied envelope only, preserving the original identity for replies. Inherited `ACP_BACKEND` and related variables are removed from the child environment.

Desktop connections register with `/api/acp/observe` and bind their MCP capability; after a daemon restart, heartbeats restore visibility and rebind the surviving capability without blocking ACP traffic.

## Deployment

The launcher starts the daemon with the installed configuration and `AUTONOM_PORT` (default 8080). `GET /api/health` reports `stopping` with 503 while the worker winds down. Development runs the same binary against a temporary configuration:

```sh
dub run --compiler=ldc2 --config=unit --build=unittest
python3 source/mcp/tests.py
```

Model simulation establishes protocol and lifecycle behavior; isolated real CLI integration establishes the catalog and metadata contract. Neither proves native Desktop presentation. Follow the [Command Center contract](launcher/patches/COMMAND_CENTER.md) before deployment or live validation.

## Reading more

- [Sessions](SESSIONS.md) — session lifecycle, catalogs, and permissions.
- [Coordination](COORDINATION.md) — rooms, events, schedules, and the on-disk layout.
- [Policy and hooks](POLICY.md) — the hook events and policy engine behind `/api/hooks/*`.