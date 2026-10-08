# Verification

- Default target is the daemon: `dub build --compiler=ldc2`.
- Tests: `dub run --compiler=ldc2 --config=unit --build=unittest`.
- Eval runner: `dub build --compiler=ldc2 --config=eval`.
- Unit tests and evals launch the production daemon on loopback port 18080; do not run them concurrently.
- Live session evals require `AUTONOM_EVAL_MODEL` and `AUTONOM_EVAL_WORKSPACE` and create/remove real Devin sessions.
- Policy-only live eval: `dub run --compiler=ldc2 --config=eval -- --policy`; requires only `OPENROUTER_API_KEY`.

# Runtime

- `autonom.app` is the executable entrypoint; `autonom.server` owns the server setup and shared runtime state.
- One persistent Serverino worker owns live session processes; do not enable idle/lifetime worker recycling.
- `AUTONOM_CONFIG` selects the YAML configuration and `AUTONOM_PORT` overrides the default loopback port 8080.

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
