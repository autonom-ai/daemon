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
- One persistent Serverino worker owns live session processes; do not enable idle/lifetime worker recycling.
- `AUTONOM_CONFIG` selects the YAML configuration and `AUTONOM_PORT` overrides the default loopback port 8080.
- Devin Desktop exports `ACP_BACKEND=windsurf`; unset it for direct CLI checks. The bridge scrubs host prefixes itself.
- Sessions must own their IDs: Serverino request strings can reference reused buffers and cannot be retained as cache keys.
- `POST /api/sessions/remove` accepts `{"ids":[...]}`; validates the entire batch and reports `removed` and `failed` IDs.

# Policy

- `POST /api/policy/check` accepts string `directory` and `tool`, with optional object `input`.
- Workspace policy is `<directory>/.devin/policy.yml`, containing a required `rules` list; files reload on each check.
- Rules use `action: allow|deny|screen`; `match` maps `tool` or input field names to regular expressions.
- First matching rule wins; no match denies. Invalid policies or unavailable decisions return HTTP 503 with `denied: true`.
- Screen rules require `question`; optional fields are `reason`, `context`, `expose`, and `threshold` (default 0.5).
- Content fields are scrubbed unless exposed; credential and session-ID fields remain scrubbed even with `expose`.
- One shared Intuit `IRouter` handles decisions; clear its context on every success and failure.
- YAML settings `policyUrl` and `policyModel` default to OpenRouter and `inception/mercury-decide:free`.
- Export `OPENROUTER_API_KEY` before launching the daemon or policy eval; `.env` is not automatically loaded.
