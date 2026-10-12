# Verification

- Default target is the daemon: `dub build --compiler=ldc2`.
- Tests: `dub run --compiler=ldc2 --config=unit --build=unittest`.
- Eval runner: `dub build --compiler=ldc2 --config=eval`.
- Unit tests and evals launch the production daemon on loopback port 18080; do not run them concurrently.
- Live evals: `dub run --compiler=ldc2 --config=eval`; runs policy and sessions by default. Export `OPENROUTER_API_KEY`.
- Select a suite with `-- --policy` or `-- --sessions`; session-only evals do not require the OpenRouter key.
- Session evals default to `swe-2-medium`; override with `AUTONOM_EVAL_MODEL` or `AUTONOM_EVAL_CLI`.
- Evals own a temporary workspace, remove only newly created sessions on success or failure, and verify cleanup.
- The eval-only CLI wrapper disables workspace trust checks for that empty temporary workspace, not user workspaces.

# Runtime

- `autonom.app` is the executable entrypoint; `autonom.server` assembles the worker-owned runtime and Serverino lifecycle.
- `autonom.agent` owns profiles and durable profile-to-session assignments. `autonom.interop` owns canonical backend session handles, process executions, and CLI integration.
- One persistent Serverino worker owns mutable registries and profile state. Execution monitor threads own only their child process and execution record; do not add Serverino workers or worker recycling.
- `autonom.events` owns pending events, schedules, session wakes, and the clock thread: `events.event` holds the pending-event store, `events.schedule` the schedule store and its endpoints, and `events.scheduler` the wake logic and background thread.
- Execution records are version 2 with a `finishedAt` timestamp; version 1 records still load. `compact` uses the CLI compaction-threshold environment override, not `/compact`; an execution may declare a `dependency` that must finish before it spawns. Session metadata and conversation history come from the CLI database; executions track daemon-owned process lifecycle.
- The daemon owns one scheduler thread. It only watches due clock times in the coordination files and pokes `POST /api/schedules/refresh` over loopback; the single worker fires due events and launches wakes during its per-request refresh, so all state stays worker-owned.
- `interop.devin.db` reads model, working directory, title, mode, timestamps, and the main conversation chain from the CLI SQLite database (`arsd-official:sqlite`, opened read-only at `sessions.db` beside `sessionLockDir`). Execution launch values are used only while a new session has no database row. Last activity is not a running-state signal; a foreign held session lock means `loaded`, not `online`.
- `AUTONOM_CONFIG` selects the required YAML configuration and `AUTONOM_PORT` overrides the default loopback port 8080.
- `templates/config.yml` is the starting configuration. `devinCommand` and `router` are required; `dataDir` defaults to the config directory and `sessionLockDir` to the Devin XDG data path. `compactOnResume` (boolean) forces compaction before every resume, and `offlineStartAfter`/`offlineCompactAfter` accept durations such as `30m` or `1h` or integer seconds.
- `autonom.router` supports `router.type: openrouter` with required `key`, `url`, and `name`; `referer` and `title` are optional. Missing or unsupported router settings fail startup; environment variables and `.env` files are not consulted for router keys.
- Devin Desktop exports `ACP_BACKEND=windsurf`; unset it for direct CLI checks. The bridge scrubs host prefixes itself.
- Sessions own their IDs: Serverino request strings can reference reused buffers and cannot be retained as cache keys.
- `POST /api/sessions` and `POST /api/print` return HTTP 202 with an execution ID. `GET /api/executions/<id>` exposes `running|stopping|succeeded|failed|stopped|interrupted`, exit status, error, session ID, and a print reply on success.
- `POST /api/executions/<id>/stop` requests cancellation without waiting for the CLI process.
- `POST /api/sessions/<id>/resume` continues a session with a prompt and returns its execution ID; the execution exposes a failed status if the backend rejects the session.
- `DELETE /api/sessions/<id>` returns one removal-execution record. `POST /api/sessions/remove` validates the whole batch and returns `{"ids":[...],"executions":[{"id":"...","sessionId":"..."}],"failed":[...]}`. Removal executes asynchronously; poll each execution and trust only `status: succeeded`.
- `templates/hooks.v1.json`, installed by the extension at `.devin/hooks.v1.json`, forwards all eight Devin hook events through `source/coord/hook.py`; replace `{{AUTONOM_ROOT}}` when installing manually. The Python hook applies a 2 GB memory limit in its launch command. Policy is on `PreToolUse`; `PermissionRequest` queues human approvals and waits in the hook process, never the Serverino worker.
- `templates/mcp_config.json`, installed at `.devin/mcp_config.json`, runs `source/coord/server.py` as the `autonom-coord` MCP server: a stdlib-only Python stdio JSON-RPC server that proxies tool calls to the daemon's HTTP API and takes the caller's session from the `session_id` the hooks inject.
- `source/coord/server.py --ensure` starts `bin/autonom-daemon` detached on `AUTONOM_PORT` and waits for health. Concurrent MCP servers single-flight under `$XDG_CACHE_HOME/autonom`; daemon output goes to `daemon-<port>.log`. A failed managed PreToolUse or PermissionRequest hook returns an explicit block, not a generic nonblocking error.
- Hook forwarding uses loopback and `AUTONOM_PORT` (default 8080), disables proxies, and authenticates with the daemon-issued `AUTONOM_RUN_TOKEN`. Managed tools and hooks bind this capability to one live execution and session; unmanaged sessions expose no Autonom MCP tools, and their ordinary tools are not screened by Autonom.
- Start, print, resume, and removal commands run as bounded, persisted executions outside the Serverino request worker; hooks can be served while those processes run.
- Backend session listing remains synchronous and is limited to two seconds; model-screening policy checks remain synchronous and are limited to eight seconds.

# Profiles

- Profiles live under `dataDir/agents`. `state.json` is the authoritative versioned snapshot of permanent session-to-profile assignments and current profile bindings.
- Legacy `sessions.json` and per-profile `session.json` files are imported once when no snapshot exists; they are retained and never rewritten. Each subsequent change atomically replaces the single snapshot.
- Store state is held in memory and flushed atomically on change; there are no lock files because the single worker owns every mutation.
- A profile is locked while its bound session is running or online; rebinding it to another session requires that session to be stopped.
- Sessions keep their profile permanently, and removing a session clears the profile binding; lookups work by name or by session.
- `human` is reserved: no session may register it, and it administers every room.

# Coordination

- Coordination state lives under `dataDir/coord`: `rooms/<name>/{messages.jsonl,profiles.json}` and `inboxes/<profile>/{dms.jsonl,pings.jsonl,cursors.json,events.json,schedules.json}` plus `wakes.json`. Workspaces keep only `.devin/policy.yml` and `.devin/hooks.v1.json`.
- `autonom.coord` owns the bus: append-only jsonl streams with the most recent 1000 entries held in memory, per-profile read cursors, and rooms with an owner, admins, and an optional involved list.
- Cursors index the in-memory window and are clamped to it on load, so a restart re-delivers at most one window per stream. Trimming shifts cursors with the window.
- Rooms are global and report themselves as unknown to profiles that cannot see them and to non-administrators; only the original owner changes admins.
- Coordination endpoints take the caller's `session` as a query parameter and require a registered session: `GET/POST /api/rooms`, `GET/DELETE /api/rooms/<name>`, `GET/POST /api/rooms/<name>/messages`, `GET/POST /api/rooms/<name>/membership`, `POST /api/rooms/<name>/admins`, `DELETE /api/rooms/<name>/admins?profile=`, and `GET/POST /api/messages` (`source=dms|pings`).
- Reading a stream advances the cursor past the entries returned, and a first read starts with the newest `limit` entries. Own posts are never unread; message text is capped at 4000 characters.
- `PreToolUse` screens every tool call through the workspace policy, then blocks every tool while the session's profile has unread events, except `mcp__autonom-coord__read_events`; it injects `session_id` into `mcp__autonom-coord__*` input, adopts a freshly started session to its profile when its first hook arrives from the wake workspace, and fails closed when profile access cannot be verified.
- `UserPromptSubmit` and `PostToolUse` inject an `additionalContext` reminder naming up to five unread events when the session's profile has any; unregistered sessions and sessions with no unread events get `{}`.

# Events

- Pending events live in `inboxes/<profile>/events.json` with at most 1000 entries, keyed by the stream entry ID so a ping and a matching room schedule surface one event. Pings always surface a `ping` event; scheduled activity surfaces `room`, `dm`, or `clock` events.
- `GET /api/events?session=` returns every pending event and clears them. Reading pings, dms, or a room clears the matching events, and events carry a nullable `schedule` field naming the schedule that matched.
- Schedules live in `inboxes/<profile>/schedules.json` and are created per profile: `GET/POST /api/schedules?session=` and `DELETE /api/schedules/<id>?session=`. Ping and dm schedules match every event or one `from` profile; room schedules also name a visible room; clock schedules take `at` (one-shot ISO-8601 timestamp) or `every` (seconds, repeats until cancelled, up to 30 days).
- `POST /api/schedules/refresh` fires due clock schedules and reconciles wakes; the scheduler thread pokes it, and every request also runs the same refresh before its handler.
- When an event fires for an offline profile: a scheduled event resumes the session (compacting first when offline longer than `offlineCompactAfter`, or always with `compactOnResume`); an unscheduled ping starts a fresh session in the pinging profile's workspace with the target's last model when offline longer than `offlineStartAfter`, else resumes. A ping whose fresh start has no pinging workspace drops the event.
- Wakes are recorded in `wakes.json` until their execution finishes: a successful start registers the new session to the profile, a failed wake re-surfaces its events, and a profile with an in-flight wake is never woken twice. Sessions that cannot be resumed only surface events.

# Policy

- Policy is enforced by the `PreToolUse` hook, which fires for every tool call regardless of permission mode: denials return `{"decision":"block","reason":"..."}` and everything else returns `{}`, so policy can auto-reject but never auto-approve. Screening cannot live on `PermissionRequest` because auto-approved and bypassed calls never reach it.
- The hook policy directory comes from the authenticated execution workspace, then the CLI database. Untrusted hook payload fields cannot select another workspace's policy.
- `POST /api/policy/check` accepts string `directory` and `tool`, with optional object `input`.
- Workspace policy is `<directory>/.devin/policy.yml`, containing a required `rules` list; files reload on each check.
- `templates/policy.yml` is the starting workspace policy, installed at `.devin/policy.yml`; it screens with `inception/mercury-decide:free`.
- Rules use `action: allow|deny|screen`; `match` maps `tool` or input field names to regular expressions.
- First matching rule wins; no match denies. Invalid policies or unavailable decisions return HTTP 503 with `denied: true`.
- Screen rules require predicate `questions` and a `models` list tried in order; `reason` defaults to null and `threshold` to 0.5.
- Screening receives the tool input unchanged; denial occurs when any answer probability meets the rule threshold.
- Config owns one shared Intuit `IRouter`; policy checks clear its context on every success and failure.
- Keep credential-bearing config files private. The live policy eval takes `OPENROUTER_API_KEY` only to write its protected temporary config; production reads the configured router key.

# Extension

- `extension/` is the VS Code / Devin Desktop extension. Its chat uses daemon-launched CLI print/resume processes, not Desktop's agent panel or a custom ACP client. Bootstrap Icons supply all UI icons; `diagram-3-fill` is used for the SVG activity-bar mark and the PNG extension icon.
- Build and verify from `extension/`: `npm ci`, `npm run check`, `npm test`, `npm audit`, `npm run package`. The VSIX is `bin/autonom-0.4.0.vsix` in the repository root. Python integration helpers: `ulimit -v 2000000 && PYTHONDONTWRITEBYTECODE=1 python3 source/coord/tests.py` from the root.
- The extension host owns HTTP, private files, workspace installation, and configuration; webviews own presentation only. Never send the OpenRouter key or client/run capabilities to a webview. Content is escaped, raw markdown HTML and remote images are disabled, and scripts use a nonce-based CSP.
- Daemon HTTP endpoints except health and authenticated hooks require `x-autonom-client` or a session-bound `x-autonom-run` capability. `dataDir/client.token` is a private owner-only control capability; `managed.json` stores daemon-origin sessions and workspace-trust snapshots. Run capabilities are in memory, expire with the execution, and cannot claim another session.
- `autonom.open` opens an editor-tab webview. The activity-bar `autonom.control` webview edits extension defaults, daemon scheduling settings, and workspace policy. Workspace setup preserves other hooks/MCP servers and never overwrites an existing policy. Secret editing uses a native password input and private atomic writes.
- `/api/client/state`, `/api/client/messages`, `/api/client/events`, `/api/client/transcript/<id>`, and `/api/client/models` support human chat and status without consuming agents' cursors. Human pings resume managed sessions without requiring a pinger workspace; viewing an agent's pending events does not clear them.
- `npm run preview` serves an explicitly in-memory UI demo on loopback port 18100. Set `AUTONOM_PREVIEW_WORKSPACE`, `AUTONOM_PREVIEW_PORT`, `AUTONOM_CONFIG`, and `AUTONOM_PORT` for a live isolated preview using the same controller. Browser previews cannot confirm destructive actions.
- Devin Desktop 1.126 does not execute `--extensionTestsPath` reliably. Validate the shared frontend with Playwright and install the packaged VSIX into isolated user-data/extensions directories; do not patch Desktop or weaken Electron sandbox flags to run host tests.
