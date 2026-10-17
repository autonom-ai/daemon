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

## ACP close-out, 2026-10-17

This later run verifies commits `7718242` and `7a0d9fd` against the installed
Devin Desktop 1.126.0, commit `0b186d6e13a1a48a46430c51fe414dd0747d46f6`.
The user's pending launcher re-pin was present in the working tree. The native
workbench SHA-256 remained
`302af387606888341f563bbbac96db129c821602a9fa2bd7f37313899450a6e1`.

All live controls targeted the separate test window
`E86DB0DC3C337760B17E784084058C06`, window ID 2, with workspace
`/tmp/autonom-live-20261017`. Actual model turns used SWE-2 Medium. Autonom was
enabled through native settings with the user's authorization and remains
enabled. No vendor bundles, profile data, or installed configuration were
rewritten.

| Gate | Observed result |
| --- | --- |
| Native and HTTP permission settlement | Approval executes once; rejection and cancellation do not execute. All three HTTP outcomes clear actual native controls; repeated decisions return 409. |
| Resume on native connection | Finished native session accepts an HTTP resume and renders `ACP_SAME_PID_RESUME_OK`; relay PID 345621 and CLI PID 345623 retain their original start times. |
| Active cancellation | Native approval starts a 30-second shell command; HTTP stop returns a stopped call and native interruption state. Its output file remains absent after the command's original deadline. |
| Headless finish and resume | Both calls on `magical-picture` finish with the expected replies and exit 0; its real CLI lock can be acquired after completion. |
| Hook ordering | Real `PreToolUse` returns `{}`, then `PermissionRequest` returns `{}`, then native ACP approval remains pending. Native approval executes the command and produces `PostToolUse`. |
| Automatic and bypassed tools | An automatic read emits `PreToolUse` and `PostToolUse`. A command in Bypass Permissions mode is blocked by an explicit workspace policy and creates no file. |
| Missing policy | Real shell, write, and read attempts fail closed when the workspace policy file is absent. An explicit local allow policy permits the subsequent approval test. |
| Installed build and installer inspection | Launcher installed-peer integration and `python3 install.py --check` pass against the current installation. |
| Real CLI frame and load integration | Exactly 16 MiB JSON passes through the production connector; one extra byte is rejected. A real CLI-persisted 1,120,027-byte prompt replays exactly on `session/load`. Fragmented/coalesced requests preserve identities; malformed input exits 1. |

The frame/load integration uses isolated XDG state without model credentials.
The CLI persists the large prompt before its expected authentication error;
the test does not fabricate database rows or invoke a model. This establishes
large text replay, not every shape of a long conversation with generated tool
results. Full D verification with `ACP_BACKEND` unset and `--d-version=devin`
passes 106 tests, with zero failures and four expected failures. Raw output is
in `/tmp/autonom-20261017-peer-full.log`.

Live raw evidence is local, under
`/tmp/autonom-live-20261017/evidence/`: `actions.jsonl`, `http.jsonl`,
`hooks.jsonl`, `http-fix-files.json`, `headless-lock.json`, `hooks-files.json`,
and the corresponding screenshots. Permission screenshots are
`http-fix-{before,approved,reject-before,rejected,cancel-before,cancelled}.png`;
other captures include `http-same-pid-resume.png`, `http-active-stop.png`,
`hooks-native-permission.png`, and `hooks-bypass-denied.png`.

The native lifecycle gates are tracked in ANM-38, frame/load acceptance in
ANM-39, and native permission withdrawal in ANM-65. The earlier Ask-to-Code
tool-availability finding remains deferred in ANM-64; fresh Code sessions work.

Hook registration remains a deployment prerequisite. The actual user CLI
configuration has no registered hooks. This run installed the template only
under the temporary test workspace's `.devin/hooks.v1.json`, with an observer
that invokes the production hook and records event timing and responses.
The local policy fixture uses deterministic allow/deny rules and invokes no
screening model. It proves the supported hook/ACP sequence; it does not claim
that every other workspace has hooks installed. The production template's
PermissionRequest timeout is now 20 seconds because ACP owns the human wait.
Global hook deployment remains open in ANM-41 within the user's existing
restriction on installed configuration changes.
