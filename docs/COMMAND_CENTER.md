# Devin Desktop Command Center adapter

## Status and safety model

The adapter is `source/launcher/`, a launcher that starts Devin Desktop with `--remote-debugging-pipe` and attaches the Command Center to the workbench renderer. It is pinned to Devin Desktop **1.126.0** and refuses to attach to any other build.

The debugging pipe is created by the launcher process and inherited as file descriptors 3 and 4 of the browser process, so the Chrome DevTools Protocol endpoint never listens on a loopback port. The default transport exposes no DevTools network endpoint. Every launcher argument is forwarded to Devin Desktop except `--debug`, which explicitly switches to a loopback WebSocket transport on port 9222 (`--debug=<port>` overrides it) for development. Debug mode verifies the browser PID matches the launched process; it is never persisted in settings or `argv.json`. The launcher strips inherited `ACP_*`, `ELECTRON_*`, `VSCODE_*`, and `WINDSURF_*` variables from the child environment so launching from a terminal inside Devin Desktop does not leak host state (such as `ELECTRON_RUN_AS_NODE` or the parent's IPC hook) into the new instance.

`install.py` replaces only the `bin/devin-desktop` CLI shim with a small direct launcher wrapper, preserving the original shim byte-for-byte. It copies the launcher bundle and runtime assets beside the Desktop installation. The Electron binary, package entrypoint, main and workbench bundles, `product.json`, and profile data are untouched. The launcher starts the sibling Electron binary with its private pipe. The adapter wraps the native navigation manifest getter and surface controller in memory and restores every descriptor on dispose. There is no checksum rewriting or integrity-warning suppression.

An already-running unmanaged Desktop must be restarted once: additional windows in that process cannot inherit a new debugging pipe. Once managed, further launches delegate their window requests to it.

## Installation

Build and test as your normal user, then install with the permissions required by the Desktop directory:

```bash
npm --prefix source/launcher ci
npm --prefix source/launcher run check
npm --prefix source/launcher test
sudo python3 install.py --no-build
```

Quit Desktop once, then run `devin-desktop` from a terminal. Your existing profile and login remain in use. The installed shim execs the launcher directly, preserving argv, cwd, stdout, stderr, and exit status; `devin-desktop --debug` therefore behaves the same as `node dist/launcher.js --debug`. The installer records the original shim for byte-for-byte rollback and copies the launcher, assets, daemon, and MCP scripts into `/usr/share/devin-desktop/autonom`. Build before installing or launching.

`python3 install.py --check` verifies status. `sudo python3 install.py --uninstall` restores the CLI shim byte-for-byte; its backup and inert installed launcher payload remain for auditing. `--app <resources/app>` selects a non-default installation. External edits or unknown versions fail closed. The installer references this checkout, so keep it in place. Desktop upgrades replace the patch and require reinstallation after rechecking compatibility. Windows and macOS startup/packaging have not been validated.

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

- Product commit: `0b186d6e13a1a48a46430c51fe414dd0747d46f6`
- Native host bundle: `out/vs/workbench/workbench.desktop.main.js`
- SHA-256: `302af387606888341f563bbbac96db129c821602a9fa2bd7f37313899450a6e1`
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

One icon-only switch replaces the native Agent/Editor presentation: Autonom, Devin Cloud, and Editor. Each mode renders its line icon while inactive and its filled variant (`autonom-fill`, `cloud-fill`, `pencil-fill`) while active. Native Agent/Editor handlers still own workbench transitions. The controls are `-webkit-app-region: no-drag`, because the surrounding titlebar is a native drag region that otherwise swallows real pointer clicks even though scripted CDP clicks still work. The switch resolves native buttons again after remounts, briefly restores their visibility when forwarding a click, and restores the original switch on detach. Styles live in `assets/ui.css`. The default Autonom page does not open or prefetch while Editor is selected.

Useful pinned theme tokens include `--text-primary`, `--text-secondary`, `--tint-secondary`, `--bg-elevated-transparent`, `--border-secondary`, and `--vscode-titleBar-activeForeground`. Prefer Devin's existing Bootstrap icon names and design-token rules over hard-coded colors or a second icon library. Native theme values and CSS rules are generated in the installed `out` assets; treat them as version-pinned observations, not a stable public API.

The actual native page-item data contract is `{id, path, label, icon}` (Desktop may add fields such as `beta` and `render`). Preserve unknown native fields and do not mutate native item objects. Custom config IDs use lowercase ASCII letters, digits, and hyphens. A custom action item maps to `/autonom/<item-id>`. Imported native items retain their original routes and metadata, so Wiki and other selected Cloud elements are the actual Desktop pages.

## Command Center assets

The definition and its content live in the repository's `assets/` directory:

- `ui.yml` defines ordered sections, items, and optional native Cloud imports.
- `ui.css` provides scoped mode-switch, section-heading, and page styles.
- `pages/*.html` are the HTML actions.
- `actions/*.js` are renderer-side asynchronous action bodies.
- `icons/*.svg` are the UI marks.

```yaml
enabled: true
active_item: schedules
devin_cloud:
    - wiki
sections:
    - id: coordination
      label: Coordination
      items:
          - id: schedules
            label: Schedules
            icon: automations
            actions:
                left_click: pages/schedules.html
    - id: knowledge
      label: Knowledge
      items:
          - id: wiki
    - id: tools
      label: Tools
      items:
          - id: reload-ui
            label: Reload UI
            actions:
                left_click: actions/reload.js
```

Sections and items render in YAML order; section labels are optional and empty labeled sections are supported. `devin_cloud` lists native manifest IDs to import. Imported entries can be placed in a section, or appear after custom entries when unplaced. No native item, including Wiki, is implicitly inserted. Imported entries cannot replace their native action with a custom script/page. Hidden items remain non-interactive. `active_item` must identify a visible HTML action and opens only in Autonom's Agent view.

Only `left_click` is supported. An `.html` file displays a native webview; a `.js` file runs as an async renderer function with `context.item`, `context.open(id)`, `context.executeCommand(command, ...args)`, `context.request(message)`, and `context.refresh()`. Example JS action: `await context.refresh();`. Scripts are trusted UI code, not sandboxed plugins; they have renderer access but no launcher Node API or daemon secret. Compilation happens through the existing CDP transport without weakening Trusted Types.

The launcher validates metadata up front, reads HTML/JS only when invoked, and caches by file identity and modification version. Repeated JS invocations reuse compilation. Edits to YAML, CSS, HTML, or JS trigger a debounced atomic reload; invalid definitions retain the last working snapshot. Layout-only reloads do not recapture native services or rebuild the runtime. Active HTML is loaded before committing a replacement snapshot, and inactive action sources stay unloaded.

Limits: 32 sections, 100 items, 64-character IDs, 200-character labels, 256 KiB per action, 1 MiB total action files, and 64 KiB each for YAML/CSS. Paths must stay beneath the definition directory and reference bounded regular no-follow files. Unknown fields, duplicate IDs, unsupported actions, malformed YAML, symlinks, and traversal fail closed. Full HTML documents keep their restrictive CSP; fragments are wrapped with no scripts or network access.

## Launcher bridge

Pages talk to the daemon through a token-authenticated loopback HTTP endpoint that the launcher owns. The injected runtime receives the endpoint URL and a random token, and forwards each `acquireVsCodeApi()` message to it; the launcher holds the daemon client capability (`dataDir/client.token`) and performs every file write. Capabilities never reach a page, a webview, or a log.

UI bridge actions are `getAction` (validated lazy HTML/JS source), `runScript` (the requesting attached window), and `reloadUi`. Daemon/settings actions: `getState` (daemon `/api/client/state` for the workspace), `getSettings`/`saveSettings` (launcher settings), `getDaemon`/`saveDaemon` (daemon YAML), `editConfig` (open the daemon configuration in Desktop), and `editPolicy` (open the workspace policy). Unknown actions fail with HTTP 400.

## Launcher settings

`~/.config/autonom/launcher.yml` owns the launcher's own values:

- `port`: daemon loopback port (default 8080).
- `configFile`: daemon YAML path (default `~/.config/autonom/config.yml`).
- `commandCenterConfig`: Command Center definition (default `assets/ui.yml`).

`AUTONOM_PORT` and `AUTONOM_CONFIG` override the file. The Settings page edits the port and the daemon parameters through the bridge.

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

`hot` re-reads `ui.yml`, asset versions, CSS, and the runtime bundle. A changed runtime is reinstalled; layout-only updates use the existing runtime. Asset edits also reload automatically. `detach` disposes the runtime and restores native Devin; `hot` resumes attachment after a detach. Control evaluations and screenshots release their temporary CDP sessions, and status reads the live renderer rather than cached state.

## Build and verification

From `source/launcher/`:

```bash
npm ci
npm run check   # tsc --noEmit
npm test        # build + unit tests
npm run build   # <repository>/dist/launcher.js and <repository>/dist/runtime.js
```

Run the built Node entrypoint from the repository root; its arguments are the Devin Desktop command line:

```bash
node dist/launcher.js /path/to/workspace
node dist/launcher.js /path/to/workspace --debug
```

Launching an installed `devin-desktop --debug` is equivalent. Identify a separate test window's exact target id through `cdp.mjs targets`, then drive only it:

```bash
node source/launcher/tests/integration/desktop.mjs <target-id> verify
```

Never target the communication window. The integration tool clicks actual rendered controls using CDP input and records DOM/runtime assertions; it does not manufacture UI state.

Unit tests cover configuration validation and path confinement, overlay immutability and descriptor rollback, provider-mode restoration, pipe framing, CDP session scoping and capture, bridge authorization, launcher settings, and the control socket. They never close a live gate.

A genuine live acceptance run quits Devin Desktop, starts the launcher, and observes through the control socket: `globalThis.__autonomCenter.status()` must report the configured mode, revision, active tab, and items; the Pages list must show the renamed rows and exclude hidden ones; the custom page webview must be present with the native content hidden; both providers must toggle on screen; and `hot` must pick up edited page content without a restart. Validate the shipped CLI wrapper, never add test-only vendor patches, weaken Electron flags, or use isolated/mutated profile data to obtain a green run. See `docs/COMMAND_CENTER_VALIDATION.md`.
