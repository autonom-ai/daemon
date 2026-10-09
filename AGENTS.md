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

- `autonom.app` is the executable entrypoint; `autonom.server` owns the server setup and shared runtime state.
- `autonom.agent` owns profiles and their endpoints; `autonom.interop` owns session contracts and the Devin CLI bridge.
- One persistent Serverino worker owns live session processes; do not enable idle/lifetime worker recycling.
- `AUTONOM_CONFIG` selects the YAML configuration and `AUTONOM_PORT` overrides the default loopback port 8080.
- Devin Desktop exports `ACP_BACKEND=windsurf`; unset it for direct CLI checks. The bridge scrubs host prefixes itself.
- Sessions must own their IDs: Serverino request strings can reference reused buffers and cannot be retained as cache keys.
- `POST /api/sessions` starts a session through a print and returns its handle; the print reply lands in the session log.
- `POST /api/sessions/<id>/resume` continues a session with a prompt; the CLI only runs sessions it already knows.
- `POST /api/sessions/remove` accepts `{"ids":[...]}`; validates the entire batch and reports `removed` and `failed` IDs.
- `.devin/hooks.v1.json` forwards all eight Devin hook events to `POST /api/hooks/<kebab-case-event>` using curl.
- Hook endpoints validate `hook_event_name` and return `{}` without granting permissions or blocking actions.
- Hook forwarding uses loopback and `AUTONOM_PORT` (default 8080), disables proxies, and times out after five seconds.
- Synchronous CLI calls occupy the sole request worker; hooks during print/session creation may time out.

# Profiles

- Profiles live under `dataDir/agents`: `sessions.json` records permanent session links, and each profile directory holds its own `session.json` binding.
- Store state is held in memory and flushed atomically on change; there are no lock files because the single worker owns every mutation.
- A profile is locked while its bound session is running or online; rebinding it to another session requires that session to be stopped.
- Sessions keep their profile permanently, and removing a session clears the profile binding; lookups work by name or by session.

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
