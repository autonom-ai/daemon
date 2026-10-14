# Devin Desktop Command Center adapter

## Status and safety model

The adapter is `source/launcher/`, a launcher that starts Devin Desktop with `--remote-debugging-pipe` and attaches the Command Center to the workbench renderer. It is pinned to Devin Desktop **1.126.0** and refuses to attach to any other build.

The debugging pipe is created by the launcher process and inherited as file descriptors 3 and 4 of the browser process, so the Chrome DevTools Protocol endpoint never listens on a loopback port. No local web page or unrelated process can reach the renderer, and there is no `--remote-debugging-port` to leave behind. The launcher strips inherited `ACP_*`, `ELECTRON_*`, `VSCODE_*`, and `WINDSURF_*` variables from the child environment so launching from a terminal inside Devin Desktop does not leak host state (such as `ELECTRON_RUN_AS_NODE` or the parent's IPC hook) into the new instance.

`install.sh` changes only the package's `main` field to an installed bootstrap, retaining a byte-for-byte original backup. The original main and workbench bundles, `product.json`, and profile data are untouched. The bootstrap hands normal GUI startup to the launcher, which starts the real application with its pipe; managed children import the original main module. The adapter wraps the native navigation manifest getter and surface controller in memory and restores every descriptor on dispose. There is no checksum rewriting or integrity-warning suppression.

An already-running unmanaged Desktop must be restarted once: additional windows in that process cannot inherit a new debugging pipe. Once managed, further launches delegate their window requests to it.

## Installation

Build and test as your normal user, then install with the permissions required by the Desktop directory:

```bash
npm --prefix source/launcher ci
npm --prefix source/launcher run check
npm --prefix source/launcher test
sudo bash install.sh --no-build
```

Quit Desktop once and launch it normally. Your existing profile and login remain in use. The bootstrap waits for its own process to exit before launching again, avoiding the profile lock race. Logs go to `$XDG_CACHE_HOME/autonom/launcher.log` or `~/.cache/autonom/launcher.log`. The install record retains the actual Node and Python executable paths so GUI startup does not depend on shell version-manager shims.

`bash install.sh --check` verifies status. `sudo bash install.sh --uninstall` restores `package.json` byte-for-byte; backups and inert bootstrap files remain for auditing. `--app <resources/app>` selects a non-default installation. External edits or unknown versions fail closed. The installer references this checkout, so keep it in place. Desktop upgrades replace the patch and require reinstallation after rechecking compatibility. Windows and macOS startup/packaging have not been validated.

## Verified native boundaries

The inspected page-list and active-surface pipeline is:

1. The workbench passes `subscribeToDesktopNavSurfaces` and `getDesktopNavSurfacesSnapshot` into the agent sidebar React context.
2. The native navigation manifest service owns the items `{id, path, icon, label}`. Its `updateManifest` writes application storage, so the adapter does **not** call it.
3. `devin.desktopNav.openSurface` selects a surface and opens the native Agent view.
4. A separate native surface controller mounts the page webview in the `windsurf-nav-surface-layer`. `ewt` is a performance/telemetry component; it is not the content pane.

The adapter temporarily wraps the in-memory manifest getter and the current window's native surface controller. It keeps a stable, cached overlay snapshot, notifies the native manifest event, and leaves React responsible for rendering its original navigation. Selecting an Autonom item calls the existing native `devin.desktopNav.openSurface` command.

Custom HTML is placed in a separate native Electron webview over that controller's existing page mount. The existing remote webview stays mounted and is hidden only while a custom page is active; no native sidebar siblings, chat, composer, or other native page are hidden. Custom webviews have no local resource roots, and a page that is a full HTML document supplies its own CSP; fragments are wrapped with `default-src 'none'` and no scripts. A 30-second lease removes the runtime wrappers if the launcher disappears.

The attach flow captures the private native references with two brief CDP debugger pauses; every breakpoint is removed and the renderer is resumed in a `finally`, and the debugger domain is disabled afterwards. Runtime reloads (`hot`) recapture those references before replacing the runtime; failed captures leave the existing runtime installed.

The sidebar React context is the only source of those services, so the agent window must be mounted before the runtime can attach. The workbench mode is persisted per workspace; if the window opens in editor mode, the launcher logs the hint and retries every five seconds until the agent window appears.

### Pin for Desktop 1.126.0

- Product commit: `fcf7ba39e6150055fad817f8716385b4d320d46d`
- Native host bundle: `out/vs/workbench/workbench.desktop.main.js`
- SHA-256: `da45742ddd56f8d83e38c4c4a57802ffe4b6cc98645a787588eda346d455f22d`
- Build: `1.126.0`, Devin Desktop / Windsurf `3.10.48`

These references point into minified private implementation details, not a supported Desktop extension API. A version, commit, hash, API-shape, or React-boundary change must fail closed and be re-researched before extending the pin. Do not replace the pin with a loose DOM heuristic.

The `devin-desktop` command in `PATH` is a shell shim that launches the CLI, which spawns the GUI with ignored stdio; the launcher therefore resolves the Electron binary beside the shim (`<root>/devin-desktop` for `<root>/bin/devin-desktop`) and spawns that directly.

## Native visual language

The sidebar uses native structural roles:

- `ul[data-slot="sidebar-menu"]` contains `li[data-slot="sidebar-menu-item"]` entries.
- `div[data-slot="sidebar-menu-button"]` is the native 30px menu surface with its active state in `data-active`.
- `button[aria-label="New session"]` identifies the real New session row.
- The primary page list has `aria-label="Pages"`; visible rows carry an accessible `aria-label` matching the page label.
- `data-slot="sidebar-button-content"` / `data-slot="sidebar-menu-button-content"` style the icon-and-label interior.

The toggle is one accessible provider row immediately before New session. Its styles live in `assets/commandCenter.css`, scoped to Autonom-owned elements and using native theme tokens. `aria-pressed` identifies the active provider. A mutation observer restores only that row after React remounts it; it never hides or rewrites native sidebar containers, groups, sessions, agent-picker buttons, or labels.

Useful pinned theme tokens include `--text-primary`, `--text-secondary`, `--tint-secondary`, `--bg-elevated-transparent`, `--border-secondary`, and `--vscode-titleBar-activeForeground`. Prefer Devin's existing Bootstrap icon names and design-token rules over hard-coded colors or a second icon library. Native theme values and CSS rules are generated in the installed `out` assets; treat them as version-pinned observations, not a stable public API.

The actual native page-item data contract is `{id, path, label, icon}` (Desktop may add fields such as `beta` and `render`). Preserve unknown native fields and do not mutate native item objects. Custom config IDs use lowercase ASCII letters, digits, and hyphens. A visible custom page item maps to `/autonom/<tab-id>`; its matching native surface keeps the original ID, so React's page activation and accessible label remain native.

## Command Center assets

The definition and its content live in the repository's `assets/` directory:

- `commandCenter.json` describes the visible pages and provider mode.
- `pages/*.html` are the page documents; `events.html`, `policy.html`, `schedules.html`, and `settings.html` ship by default.
- `icons/*.svg` are the Autonom marks.
- `commandCenter.css` defines scoped provider and custom-page styles. Runtime UI assets are inlined at build time.

Example:

```json
{
    "enabled": true,
    "items": [
        { "id": "schedules", "label": "Schedules", "icon": "automations", "tab": "schedules" },
        { "id": "security", "hidden": true }
    ],
    "tabs": {
        "schedules": { "title": "Schedules", "file": "pages/schedules.html" }
    },
    "activeTab": "schedules"
}
```

A native item is renamed by its exact manifest `id`; `{ "id": "security", "hidden": true }` removes a native row for Autonom mode only. A custom item needs a `tab`; a native item with no `tab` keeps its original native `path` and content. The Autonom/Devin Cloud toggle is transient per attached window. Devin Cloud mode returns the original native manifest and shows the original native surface. The configuration remains loaded, so selecting Autonom restores its configured overlay without restarting Desktop.

Config rules:

- `enabled` must be boolean. `items` and `tabs` are capped at 100 entries each; IDs are capped at 64 ASCII characters.
- Each page file is a regular no-follow file beneath the directory containing `commandCenter.json`, capped at 256 KiB. All page content combined is capped at 1 MiB. Titles are capped at 200 characters.
- Invalid JSON, invalid schema, duplicate IDs, unknown tab references, symlinks, and path traversal reject the complete load; the last valid native snapshot remains active.
- Page contents are trusted repository-authored HTML. Full documents keep their own CSP and are allowed to run inline scripts so they can talk to the bridge; fragments are wrapped with `default-src 'none'` and no scripts. Do not enable remote resources.

## Launcher bridge

Pages talk to the daemon through a token-authenticated loopback HTTP endpoint that the launcher owns. The injected runtime receives the endpoint URL and a random token, and forwards each `acquireVsCodeApi()` message to it; the launcher holds the daemon client capability (`dataDir/client.token`) and performs every file write. Capabilities never reach a page, a webview, or a log.

Bridge actions: `getState` (daemon `/api/client/state` for the workspace), `getSettings`/`saveSettings` (launcher settings), `getDaemon`/`saveDaemon` (daemon YAML), `editConfig` (open the daemon configuration in Desktop), and `editPolicy` (open the workspace policy). Unknown actions fail with HTTP 400.

## Launcher settings

`~/.config/autonom/launcher.yml` owns the launcher's own values:

- `port`: daemon loopback port (default 8080).
- `configFile`: daemon YAML path (default `~/.config/autonom/config.yml`).
- `commandCenterConfig`: Command Center definition (default `assets/commandCenter.json`).

`--port`, `--daemon-config`, `--config`, `--desktop`, `--socket`, `AUTONOM_PORT`, and `AUTONOM_CONFIG` override the file. The Settings page edits the port and the daemon parameters through the bridge.

## Control socket

The launcher serves `$XDG_RUNTIME_DIR/autonom/launcher.sock` with mode 0600. It is a private, same-user channel for inspection and never a network endpoint:

```bash
node source/launcher/cdp.mjs status
node source/launcher/cdp.mjs targets
node source/launcher/cdp.mjs eval workbench "globalThis.__autonomCenter.status()"
node source/launcher/cdp.mjs screenshot workbench /tmp/autonom.png
node source/launcher/cdp.mjs hot
node source/launcher/cdp.mjs detach
```

`hot` re-reads `commandCenter.json` and the rebuilt runtime bundle and re-attaches every window without restarting Desktop. `detach` disposes the runtime and restores native Devin; `hot` resumes attachment after a detach. Control evaluations and screenshots release their temporary CDP sessions, and status reads the live renderer rather than cached state.

## Build and verification

From `source/launcher/`:

```bash
npm ci
npm run check   # tsc --noEmit
npm test        # build + unit tests
npm run build   # <repository>/dist/launcher.js and <repository>/dist/runtime.js
```

Then run the launcher from anywhere; it rebuilds `dist/` when sources or assets are newer:

```bash
python3 source/launcher/run.py /path/to/workspace
```

Unit tests cover configuration validation and path confinement, overlay immutability and descriptor rollback, provider-mode restoration, pipe framing, CDP session scoping and capture, bridge authorization, launcher settings, and the control socket. They never close a live gate.

A genuine live acceptance run quits Devin Desktop, starts the launcher, and observes through the control socket: `globalThis.__autonomCenter.status()` must report the configured mode, revision, active tab, and items; the Pages list must show the renamed rows and exclude hidden ones; the custom page webview must be present with the native content hidden; both providers must toggle on screen; and `hot` must pick up edited page content without a restart. Validate the shipped startup bootstrap, never add test-only vendor patches, weaken Electron flags, or use isolated/mutated profile data to obtain a green run. See `docs/COMMAND_CENTER_VALIDATION.md`.
