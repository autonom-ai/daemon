# Command Center validation methodology

This document is the acceptance procedure for the `devin/launcher/` Command Center adapter. It exists because an earlier iteration failed on exactly this point: it reported success from tests that manufactured the UI state they were meant to observe. Read `docs/COMMAND_CENTER.md` first for the architecture and safety contract; this document defines how to prove behavior against a real, logged-in Devin Desktop.

## The one rule

**A test may only observe; it may never synthesize the product surface it is validating.** Do not construct the sidebar, inject the toggle, mount a settings layer, or seed a fake manifest inside a test. If the product does not render it, the test must fail. Everything below follows from that rule.

Corollaries:

- A green unit test proves the module, not the integration. It never closes a live gate.
- A screenshot is evidence only when paired with the DOM/state assertions that explain what changed.
- "It looked right" is not evidence. Record the exact command, target id, and observable values.
- Never weaken a control to make a test pass: no disabling the integrity service, no rewriting checksums, no loosening CSP, no test-only vendor patches, no mutating the profile data directory. The installed CLI wrapper is part of the product under test, not a validation workaround.

## Layers of evidence

| Layer | What it proves | What it cannot prove |
| --- | --- | --- |
| `npm run check` | Types and API shape compile | Runtime behavior |
| `npm test` (unit) | Pure logic: config validation and confinement, overlay math, descriptor rollback, pipe framing, CDP session scoping, bridge authorization, control socket | Desktop integration |
| Live launcher run | The built launcher attaches to the installed Desktop | Nothing beyond the tested build |
| Adversarial/negative test | The system fails closed on hostile or malformed input | Happy-path correctness |

A release needs all four. Unit coverage lives in `devin/tests/unit/`: `center/content.ts` (overlay math, page CSP), `center/config.ts` (schema, confinement, size caps), `center/runtime.ts` (overlay immutability, descriptor rollback, provider mode), `desktop/process.ts` (pipe framing, binary resolution, build pin), `cdp/client.ts` (request correlation, session scoping, capture), `config.ts` (settings and daemon YAML), `center/bridge.ts` (authorization and actions), `cdp/control.ts` (socket protocol).

## Live acceptance procedure

### 1. Preconditions

- Devin Desktop **1.126.0**, commit `0b186d6e13a1a48a46430c51fe414dd0747d46f6`.
- Native host bundle `out/vs/workbench/workbench.desktop.main.js` SHA-256 `302af387606888341f563bbbac96db129c821602a9fa2bd7f37313899450a6e1`.
- No running Devin Desktop window: the pipe must reach the browser process the launcher spawns.
- The repository `assets/ui.yml` and its `pages/*.html` files are present.
- No concurrent change to Desktop's `user-data-dir`.

Record the pristine baseline before touching anything:

```bash
pgrep -af devin-desktop
ss -ltnp 'sport = :9882'
sha256sum /usr/share/devin-desktop/resources/app/out/vs/workbench/workbench.desktop.main.js
```

### 2. Build and launch

```bash
cd devin
npm ci
npm run check
npm test
cd ..
node dist/launcher.js /abs/path/to/workspace
```

For installed-startup validation, run `sudo python3 devin/install.py --no-build`, quit Desktop once, then run `devin-desktop --debug` from a terminal. The installed CLI wrapper must behave exactly like `node dist/launcher.js --debug`, without changing the logged-in profile.

The launcher verifies the build pin before spawning Desktop, starts the page bridge and control socket, launches Desktop with `--remote-debugging-pipe`, and attaches eligible workbench or sessions windows. It prints the workspace and control socket. If Desktop opens in editor mode, open the agent window (Ctrl+') and the launcher attaches within five seconds.

Do not copy or replace the user-data directory to get a "clean" run — test the real profile.

### 3. Observe through the control socket

```bash
node devin/launcher/cdp/control.mjs status
node devin/launcher/cdp/control.mjs targets
node devin/launcher/cdp/control.mjs eval workbench "globalThis.__autonomCenter.status()"
node devin/launcher/cdp/control.mjs screenshot workbench /tmp/autonom-autonom.png
```

Assert:

- `status` reports the expected `mode`, `enabled`, `revision`, `activeItem`, and item labels.
- The Pages list contains the configured rows and excludes hidden ones.
- The custom page webview is present and the native content is hidden while it is active.
- No extra or unexpected sidebar rows exist.
- Default pipe mode has no DevTools listener. Explicit `--debug[=port]` mode listens only on loopback and verifies the browser PID.
- Never click or navigate the communication window. Use a separate test window and its exact target ID through the control socket; launch Desktop with `devin-desktop --debug` to expose the loopback endpoint.
- `node devin/tests/integration/desktop.mjs <id> verify` checks repeated HTML selection, three Cloud/Editor/Autonom cycles, imported Wiki navigation, and the JS reload action.

Capture a screenshot for each state and keep it beside the assertion output.

### 4. Toggle both providers

Click the on-screen toggle (not a programmatic state set) and re-assert:

- Autonom mode: configured labels/pages present.
- Devin Cloud mode: `mode === "devin-cloud"`, native labels restored, custom page removed.
- Toggling back restores Autonom without a window reload.

### 5. Reload content without restarting

Edit a page file, then:

```bash
node devin/launcher/cdp/control.mjs hot
```

Confirm the new content renders in the same window. This is the rapid-iteration path and must not require a Desktop restart.

### 6. Fail-closed and negative checks

Prove the guardrails, not just the happy path:

- Invalid YAML, unknown imported element, unsupported action, duplicate id, symlink, or traversal in the definition → the launcher refuses to start before spawning Desktop; the last valid state stays active on `hot`.
- A build with a different version, commit, or hash → refused with "Unsupported Devin Desktop build" or "not the verified pristine build".
- A subsequent launcher invocation delegates the window request to the already-managed Desktop without creating another pipe owner. A duplicate control server cannot take over its live socket.
- A bridge request with a wrong or missing token → HTTP 403; an unknown action → HTTP 400.
- Killing the launcher (`Ctrl+C`, `SIGKILL`) → the 30-second lease expires and the runtime wrappers are removed.
- Starting the launcher while Desktop already runs → the spawn exits and the launcher reports that Desktop exited before attaching.

### 7. Integrity check

Confirm only the `bin/devin-desktop` wrapper, its byte-for-byte `.autonom.orig` backup, and copied launcher payload changed the installation. The package entrypoint, Electron binary, vendor bundles, `product.json`, CSP, and profile data must remain unchanged:

```bash
git status --short
sha256sum /usr/share/devin-desktop/resources/app/out/vs/workbench/workbench.desktop.main.js
```

There is no integrity-suppression path. The installer does not change any checksum-managed bundle or `product.json`. Any corruption warning must be investigated, never hidden.

### 8. Clean up

```bash
node devin/launcher/cdp/control.mjs detach
```

Verify native labels and navigation return, then stop the launcher. Desktop keeps running without the Command Center overlay.

## Rapid iteration loop

While developing the runtime bundle or the pages:

```bash
npm --prefix devin run build
node devin/launcher/cdp/control.mjs hot
```

`hot` re-reads the definition and the rebuilt runtime and re-installs it in place. Use it for runtime/UI changes; the full launcher restart is still required to validate the launch path itself.

## Recording results

For each run, record:

- Desktop version, commit, native bundle hash.
- Launcher command, settings, and the exact control-socket calls with raw output.
- Screenshot paths for Autonom and Devin Cloud.
- Pass/fail per assertion, and any deviation.

Store raw output rather than a summary. If a claim cannot be backed by a captured artifact, it did not happen.
