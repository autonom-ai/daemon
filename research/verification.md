# Verification Snapshot

These are command results at repository HEAD
`08a8af4bb4321021c3f4ef4f167ea14d55c23dc1` on branch `interactive-acp`.
Each command ran once. No package install, network access, eval, live Desktop
launch, or live Desktop UI validation was performed.

| Check | Result | Time |
| --- | --- | ---: |
| `npm --prefix source/launcher run check` | Exit 0 | 1.568 s |
| `npm --prefix source/launcher test` | Exit 0; 79 passed, 0 failed | 19.763 s |
| `python3 source/mcp/tests.py` | Exit 0; 9 passed, 0 failed | 1.155 s |
| `dub build --compiler=ldc2 --config=daemon --skip-registry=all` | Exit 0; targets up to date | 0.234 s |
| `dub run --compiler=ldc2 --config=unit --build=unittest --skip-registry=all` | Exit 0; 97 passed, 0 failed | 11.054 s |

## Conditions and limits

- Port 18080 had no listener before or after the D unit tests. The tests used
  `source/tests/fakeagent.py` and temporary workspaces.
- No Desktop, `autonom-daemon`, or test process was stopped or adopted. The
  existing Devin Desktop process tree and its `autonom-acp` child (PID 24881)
  were observed before and after and left untouched.
- Launcher tests build into ignored `dist/`. The installer unit tests exercise
  temporary file trees; passing them is not an installed Desktop or live-UI
  acceptance result.
- The launcher checks/test results concern TypeScript/unit behavior. They do
  not prove the native Desktop runtime against an actual window.
- The D build and unit run used `--skip-registry=all`; existing local Dub
  dependencies were sufficient.
- No eval result is recorded. The repository's current `AGENTS.md` and CI
  mention an eval configuration, while the audited `dub.json` declares only
  `daemon`, `unit`, and `relay`.

Raw command output, stderr, exit status, timing, and process/port snapshots are
in `/tmp/autonom-verification-20261016T201846Z-136803/`. The per-command
artifacts are `01` through `05`; `preflight.txt` and `postcheck.txt` preserve
environment observations. An ancillary evidence-capture shell block initially
had a syntax error; it was corrected without rerunning any verification
command.
