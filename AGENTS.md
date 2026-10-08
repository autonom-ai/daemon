# Verification

- Default target is the daemon: `dub build --compiler=ldc2`.
- Tests: `dub run --compiler=ldc2 --config=unit --build=unittest`.
- Eval runner: `dub build --compiler=ldc2 --config=eval`.
- Unit tests and evals launch the production daemon on loopback port 18080; do not run them concurrently.
- Live evals require `AUTONOM_EVAL_MODEL` and `AUTONOM_EVAL_WORKSPACE` and create/remove real Devin sessions.

# Runtime

- `autonom.app` is the executable entrypoint; `autonom.server` owns the server setup and shared runtime state.
- One persistent Serverino worker owns live session processes; do not enable idle/lifetime worker recycling.
- `AUTONOM_CONFIG` selects the YAML configuration and `AUTONOM_PORT` overrides the default loopback port 8080.
