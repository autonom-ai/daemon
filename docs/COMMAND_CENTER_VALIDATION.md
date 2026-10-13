# Command Center validation methodology

This document is the acceptance procedure for `cet.autonom-command-center`. It exists because the previous iteration failed on exactly this point: it reported success from tests that manufactured the UI state they were meant to observe. Read `docs/COMMAND_CENTER.md` first for the architecture and safety contract; this document defines how to prove behavior against a real, logged-in Devin Desktop.

## The one rule

**A test may only observe; it may never synthesize the product surface it is validating.** Do not construct the sidebar, inject the toggle, mount a settings layer, or seed a fake manifest inside a test. If the product does not render it, the test must fail. Everything below follows from that rule.

Corollaries:

- A green unit test proves the module, not the integration. It never closes a live gate.
- A screenshot is evidence only when paired with the DOM/state assertions that explain what changed.
- "It looked right" is not evidence. Record the exact command, target id, and observable values.
- Never weaken a control to make a test pass: no disabling the integrity service, no rewriting checksums, no loosening CSP, no editing vendor files, no mutating the profile data directory.

## Layers of evidence

| Layer | What it proves | What it cannot prove |
| --- | --- | --- |
| `npm run check` | Types and API shape compile | Runtime behavior |
| `npm test` (unit) | Pure logic: schema validation, overlay math, rollback, CDP framing | Desktop integration |
| Installed-VSIX live test | The packaged artifact works in Devin Desktop | Nothing beyond the tested build |
| Adversarial/negative test | The system fails closed on hostile or malformed input | Happy-path correctness |

A release needs all four. Unit coverage for this work lives in `extension/tests/unit/`: `center.ts` (config schema, path confinement, CSP), `native.ts` (overlay immutability, descriptor rollback, provider mode), `cdp.ts` (loopback enforcement, bounded protocol handling, build pinning, identity matching).

## Live acceptance procedure

### 1. Preconditions

- Devin Desktop **1.126.0**, commit `fcf7ba39e6150055fad817f8716385b4d320d46d`.
- Native host bundle `out/vs/workbench/workbench.desktop.main.js` SHA-256 `da45742ddd56f8d83e38c4c4a57802ffe4b6cc98645a787588eda346d455f22d`.
- The legacy `cet.autonom` 0.4.0 extension is **disabled**. It edits vendor files and would contaminate results.
- A trusted workspace containing `.devin/commandCenter.json` and its referenced page files.
- No concurrent change to Desktop's `user-data-dir`.

Record the pristine baseline before touching anything:

```bash
ss -ltnp 'sport = :9882'
curl --noproxy '*' -sS http://127.0.0.1:9882/json/version
devin-desktop --list-extensions --show-versions
```

### 2. Launch with the debug port

The extension host reaches the renderer over loopback CDP. Launch the already-logged-in instance:

```bash
devin-desktop --remote-debugging-port=9882 --disable-extension cet.autonom &
```

The `Warning: 'remote-debugging-port' is not in the list of known options` message is expected; Electron forwards it. Do not copy or replace the user-data directory to get a "clean" run — test the real profile.

### 3. Install the artifact

```bash
cd extension && npm run package
devin-desktop --install-extension ../bin/autonom-command-center-0.5.2.vsix --force
```

Installing while Desktop runs can restart or close windows. Warn the user first, and prefer completing all source changes before installing. After install, confirm the version with `--list-extensions --show-versions`.

### 4. Attach and observe

`extension/.devin/cdp.mjs` is the inspection harness. It attaches to one target and supports `targets`, `eval`, `screenshot`, `command`, `install`, and `hot`. Target selection matches a `page` (or `iframe`) whose id or URL contains the argument.

Drive the **installed** extension through its own commands rather than calling the runtime directly, so the test exercises the shipped code path:

```bash
node .devin/cdp.mjs command <workbenchTargetId> \
  '{"command":"autonomCenter.attach","arguments":["/abs/path/.devin/commandCenter.json"]}'
```

Assert, in the same target:

- `globalThis.__autonomCenter.status()` reports the expected `mode`, `enabled`, `revision`, `activeTab`, and item labels.
- The Pages list contains the renamed item and excludes hidden ones.
- The custom page webview is present and the native content is hidden while it is active.
- No extra or unexpected sidebar rows exist.

Capture a screenshot for each state and keep it beside the assertion output.

### 5. Toggle both providers

Click the on-screen toggle (not a programmatic state set) and re-assert:

- Autonom mode: configured labels/pages present.
- Devin Cloud mode: `mode === "devin-cloud"`, native labels restored, custom page removed.
- Toggling back restores Autonom without a window reload.

### 6. Reload content without restarting

Edit the referenced HTML, then run `autonomCenter.reload` and confirm the new content renders in the same window. This is the rapid-iteration path and must not require an install or reload.

### 7. Fail-closed and negative checks

Prove the guardrails, not just the happy path:

- Invalid JSON, unknown tab reference, duplicate id, symlink, or traversal in the config → reload rejected, last valid state intact.
- A build with a different commit/hash → attach refused with "Unsupported Desktop build".
- No matching renderer, or two matching renderers → identity discovery fails closed.
- Wrong owner → install refused.
- Unattended crash → heartbeat expires and wrappers are removed.

### 8. Integrity check

Confirm the integrity warning behavior matches `docs/COMMAND_CENTER.md`: it is dismissed only for the exact verified legacy residue, and any other mismatch leaves the native warning visible. Never dismiss a warning you cannot fully account for.

### 9. Clean up

Run `autonomCenter.disable` and verify native labels and navigation return. Then confirm no vendor file, `product.json`, CSP, or profile-data change occurred:

```bash
git status --short
```

## Rapid iteration loop

While developing the runtime bundle, rebuild and push it into the running renderer without a Desktop restart:

```bash
cd extension && npm run build
node .devin/cdp.mjs hot <workbenchTargetId> '{"enabled":true,...}'
```

`hot` captures the native service references, then calls `AutonomNative.replace(...)`, which disposes the previous runtime and installs the rebuilt one in place. Use it for runtime/UI changes. The installed-extension path (`npm run package` + `--install-extension`) is still required to validate that the **shipped** artifact works; `hot` alone never closes a release gate.

## Recording results

For each run, record:

- Desktop version, commit, native bundle hash.
- Installed extension version and target id.
- Every command issued and its raw output.
- Screenshot paths for Autonom and Devin Cloud.
- Pass/fail per assertion, and any deviation.

Store raw output rather than a summary. If a claim cannot be backed by a captured artifact, it did not happen.
