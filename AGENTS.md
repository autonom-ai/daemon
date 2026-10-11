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
- `AUTONOM_CONFIG` selects the YAML configuration and `AUTONOM_PORT` overrides the default loopback port 8080.
- Devin Desktop exports `ACP_BACKEND=windsurf`; unset it for direct CLI checks. The bridge scrubs host prefixes itself.
- Sessions own their IDs: Serverino request strings can reference reused buffers and cannot be retained as cache keys.
- `POST /api/sessions` and `POST /api/print` return HTTP 202 with an execution ID. `GET /api/executions/<id>` exposes `running|stopping|succeeded|failed|stopped|interrupted`, exit status, error, session ID, and a print reply on success.
- `POST /api/executions/<id>/stop` requests cancellation without waiting for the CLI process.
- `POST /api/sessions/<id>/resume` continues a session with a prompt and returns its execution ID; the execution exposes a failed status if the backend rejects the session.
- `DELETE /api/sessions/<id>` returns one removal-execution record. `POST /api/sessions/remove` validates the whole batch and returns `{"ids":[...],"executions":[{"id":"...","sessionId":"..."}],"failed":[...]}`. Removal executes asynchronously; poll each execution and trust only `status: succeeded`.
- `templates/hooks.v1.json`, installed at `.devin/hooks.v1.json`, forwards all eight Devin hook events to `POST /api/hooks/<kebab-case-event>` using curl.
- `PreToolUse` evaluates workspace policy and returns `{"decision":"block","reason":"..."}` on denial or failure, or `{}` when allowed; remaining hook endpoints return `{}`.
- Hook forwarding uses loopback and `AUTONOM_PORT` (default 8080), disables proxies, and times out after five seconds (ten seconds for pre-tool policy screening).
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

- Coordination state lives under `dataDir/coord`: `rooms/<name>/{messages.jsonl,profiles.json}` and `inboxes/<profile>/{dms.jsonl,pings.jsonl,cursors.json}`. Workspaces keep only `.devin/policy.yml` and `.devin/hooks.v1.json`.
- `autonom.coord` owns the bus: append-only jsonl streams with the most recent 1000 entries held in memory, per-profile read cursors, and rooms with an owner, admins, and an optional involved list.
- Cursors index the in-memory window and are clamped to it on load, so a restart re-delivers at most one window per stream. Trimming shifts cursors with the window.
- Rooms are global and report themselves as unknown to profiles that cannot see them and to non-administrators; only the original owner changes admins.
- Coordination endpoints take the caller's `session` as a query parameter and require a registered session: `GET/POST /api/rooms`, `GET/DELETE /api/rooms/<name>`, `GET/POST /api/rooms/<name>/messages`, `GET/POST /api/rooms/<name>/membership`, `POST /api/rooms/<name>/admins`, `DELETE /api/rooms/<name>/admins?profile=`, and `GET/POST /api/messages` (`source=dms|pings`).
- Reading a stream advances the cursor past the entries returned, and a first read starts with the newest `limit` entries. Own posts are never unread; message text is capped at 4000 characters.
- `PreToolUse` blocks every tool while the session's profile has unread pings, except `mcp__autonom-coord__read_messages` with `source: "pings"`; it injects `session_id` into `mcp__autonom-coord__*` input and fails closed when profile access cannot be verified.

# Policy

- `POST /api/policy/check` accepts string `directory` and `tool`, with optional object `input`.
- Workspace policy is `<directory>/.devin/policy.yml`, containing a required `rules` list; files reload on each check.
- Rules use `action: allow|deny|screen`; `match` maps `tool` or input field names to regular expressions.
- First matching rule wins; no match denies. Invalid policies or unavailable decisions return HTTP 503 with `denied: true`.
- Screen rules require a `questions` list of named predicate `DecisionQuestion`s; optional fields are `reason` and `threshold` (default 0.5).
- Screening receives the tool input unchanged; denial occurs when any answer probability meets the rule threshold.
- One shared Intuit `IRouter` handles decisions; clear its context on every success and failure.
- YAML settings `policyUrl` and `policyModel` default to OpenRouter and `inception/mercury-decide:free`.
- Export `OPENROUTER_API_KEY` before launching the daemon or policy eval; `.env` is not automatically loaded.
