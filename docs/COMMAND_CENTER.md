# Command Center

The Command Center is the launcher in `devin/launcher/`. It starts Devin Desktop with a private debugging pipe, attaches to the workbench renderer over CDP, and injects a sidebar that lists Autonom's rooms, profiles, and pages. It replaces one native presentation — the Agent/Editor switch — and restores every descriptor it touches.

## Status and safety model

The debugging pipe is created by the launcher and inherited as file descriptors 3 and 4 of the browser process, so the DevTools endpoint never listens on a port. `--debug` switches to a loopback WebSocket on port 9222 for development (`--debug=<port>` overrides it); debug mode is never persisted in settings or `argv.json`. The launcher strips inherited `ACP_*`, `ELECTRON_*`, `VSCODE_*`, and `WINDSURF_*` variables so launching from a terminal inside Desktop does not leak host state into the new instance.

`devin/install.py` replaces only the `bin/devin-desktop` shim, preserving the original byte-for-byte, and copies the launcher bundle and assets beside the Desktop installation. The Electron binary, package entrypoint, main and workbench bundles, `product.json`, CSP, and profile data are untouched. There is no checksum rewriting and no integrity-warning suppression. The adapter wraps the native navigation manifest getter and the window's surface controller in memory, and restores every descriptor on dispose.

Before spawning Desktop the launcher reconciles the local ACP connector registry: it removes any existing `devin-autonom` entry from `~/.windsurf/acp/registry.json` and appends a canonical one pointing at the co-located `bin/autonom-acp`, passing `--config <daemon config>` and `--devin <devinCommand>`. It also sets `devin-autonom: true` under `devin.acp.enabledAgents` and `windsurf.acp.enabledAgents` in Desktop's user `settings.json`. A missing agent binary or unreadable file logs a warning and never blocks the launch; the installer performs no registry writes of its own.

An already-running unmanaged Desktop must be restarted once: a second window in that process cannot inherit a new pipe. After that, further launches delegate their window requests to the managed instance.

## Pin

The launcher refuses any build other than these, and a version, commit, hash, API-shape, or React-boundary change must be re-researched before the pin moves:

| Value | Pin |
| --- | --- |
| Desktop version | `1.126.0` |
| Product commit | `0b186d6e13a1a48a46430c51fe414dd0747d46f6` |
| Native host bundle | `out/vs/workbench/workbench.desktop.main.js` |
| Bundle SHA-256 | `302af387606888341f563bbbac96db129c821602a9fa2bd7f37313899450a6e1` |

These are minified private implementation details, not a supported extension API. Do not replace the pin with a DOM heuristic.

## Verified native boundaries

The inspected navigation pipeline is:

1. The workbench passes `subscribeToDesktopNavSurfaces` and `getDesktopNavSurfacesSnapshot` into the agent sidebar React context.
2. The native manifest service owns items of the form `{id, path, icon, label}`. Its `updateManifest` writes application storage, so the adapter does **not** call it.
3. `devin.desktopNav.openSurface` selects a surface and opens the native Agent view.
4. A separate surface controller mounts the page webview in the `windsurf-nav-surface-layer`.

Selecting an Autonom item calls `devin.desktopNav.openSurface`. The adapter keeps a stable cached overlay snapshot, notifies the native manifest event, and leaves React responsible for rendering.

Custom HTML is placed in a separate native webview over the controller's existing page mount. The native remote webview stays mounted and is hidden only while a custom page is active; no native sidebar siblings, chat, composer, or other page is hidden. Custom webviews have no local resource roots, and a full HTML document supplies its own CSP; fragments are wrapped with `default-src 'none'` and no scripts. A 30-second lease removes the runtime wrappers if the launcher disappears.

The attach flow captures the private native references with two brief CDP debugger pauses; every breakpoint is removed and the renderer resumed in a `finally`, and the debugger domain is disabled afterwards. `hot` recaptures those references before replacing the runtime, and a failed capture leaves the existing runtime installed.

## Native visual language

The sidebar uses native structural roles:

| Element | Role |
| --- | --- |
| `ul[data-slot="sidebar-menu"]` | Contains `li[data-slot="sidebar-menu-item"]` entries. |
| `div[data-slot="sidebar-menu-button"]` | The native 30px menu surface; `data-active` carries its active state. |
| `button[aria-label="New session"]` | The native New session row. |
| `aria-label="Pages"` | The primary page list; visible rows carry an accessible label matching the page. |
| `data-slot="sidebar-button-content"` / `data-slot="sidebar-menu-button-content"` | Icon-and-label interior. |
| `div[data-slot="sidebar-label-row"]` / `div[data-slot="sidebar-group-label"]` | Section header surface reused for custom labels, header buttons, and inline search. |

One icon-only switch replaces the native Agent/Editor presentation: Autonom, Devin Cloud, and Editor. Each renders a line icon while inactive and a filled variant (`autonom-fill`, `cloud-fill`, `pencil-fill`) while active. Native Agent/Editor handlers still own workbench transitions. The controls are `-webkit-app-region: no-drag`, because the surrounding titlebar is a native drag region that swallows real pointer clicks even when scripted clicks still work. The switch resolves native buttons again after remounts, briefly restores their visibility when forwarding a click, and restores the original switch on detach. Styles live in `assets/ui.css`.

Selecting Autonom always leaves the Agent sidebar visible. The switch host lives in the left header, so it stays reachable while the workbench root carries `noauxiliarybar`; after the native transition the runtime asks the workbench to focus the auxiliary bar (`workbench.action.focusAuxiliaryBar`) whenever the sidebar is still hidden. The launcher never toggles the sidebar on its own — attachment still requires a mounted agent window, and a window that never mounts one keeps logging the sidebar hint until the user opens the Agent view.

Useful pinned theme tokens include `--text-primary`, `--text-secondary`, `--tint-secondary`, `--bg-elevated-transparent`, `--border-secondary`, and `--vscode-titleBar-activeForeground`. Prefer Devin's Bootstrap icon names and design tokens over hard-coded colors or a second icon library. Treat generated theme values as version-pinned observations, not a stable API.

Native page items are `{id, path, label, icon}`; Desktop may add fields such as `beta` and `render`. Preserve unknown fields and never mutate native item objects. Custom IDs must start with a lowercase letter and continue with lowercase letters, digits, or hyphens, up to 64 characters. A custom action item maps to `/autonom/<item-id>`. Imported native items keep their original routes and metadata, so Wiki and other selected Cloud elements are the actual Desktop pages.

## Sidebar definition

The definition and its content live in `assets/`:

| File | Contents |
| --- | --- |
| `ui.yml` | Ordered sections, items, and optional native Cloud imports. |
| `ui.css` | Scoped mode-switch, section-heading, and page styles. |
| `pages/*.html` | HTML actions. |
| `actions/*.js` | Renderer-side asynchronous action bodies. |
| `icons/*.svg` | The UI marks. |

```yaml
enabled: true
devin_cloud:
    - wiki

items:
    - id: schedules
      label: Schedules
      icon: timer
      actions:
          left_click: pages/schedules.html

sections:
    - id: rooms
      label: Rooms
      buttons:
          - id: rooms-search
            search: true
          - id: rooms-new
            label: New room
            icon: plus
            actions:
                left_click: actions/new-room.js
      items: []
```

Sections and items render in YAML order, with top-level `items` ahead of the sections. Section labels are optional and empty labeled sections are supported. `devin_cloud` lists native manifest IDs to import, plus the reserved ID `spaces`; imported entries can be placed in a section or follow the top-level items when unplaced. No native item, including Wiki, is inserted implicitly. In Autonom mode the native Spaces section is hidden unless `spaces` is listed; `spaces` never creates an item and only keeps that region visible. Devin Cloud mode always restores the native sidebar, including Spaces. Imported entries cannot replace their native action with a custom script or page, and hidden items remain non-interactive.

`active_item` is optional. When set it must identify a visible HTML action, and it opens only in Autonom's Agent view; the shipped definition leaves it unset so Autonom mode opens on the native New session row instead of a page. The default Autonom page is neither opened nor prefetched while Editor is selected.

A labeled section may carry `buttons` rendered on its label row with the native Spaces header styling. Fields are `id` (required), `label` (tooltip/aria-label, at most 200 characters), `icon` (`search`, `plus`, or `sliders`), `hidden`, `search`, and `actions`. A `search: true` button opens a built-in inline field that filters the section's rows and cannot have an action; every other visible button requires `actions.left_click` pointing at a `.js` file inside the assets directory. Button IDs share the item ID namespace and element count.

Navigation item icons resolve from the bundled Lucide-derived SVGs in `assets/icons/` (`timer`, `shield-lock`, `cog`, `plus`, `search`, `sliders`), so they render independently of whatever icon set a native Cloud item uses.

The launcher validates metadata up front, reads HTML and JS only when invoked, and caches by file identity and modification version. Edits to YAML, CSS, HTML, or JS trigger a debounced atomic reload; invalid definitions retain the last working snapshot. Layout-only reloads do not recapture native services or rebuild the runtime. Active HTML loads before a replacement snapshot is committed, and inactive sources stay unloaded.

Limits: 32 sections, 100 items and section buttons combined, 64-character IDs, 200-character labels, 256 KiB per action, 1 MiB total action files, and 64 KiB each for YAML and CSS. Paths must stay beneath the definition directory and reference bounded regular non-symlink files. Unknown fields, duplicate IDs, unsupported actions, malformed YAML, symlinks, and traversal fail closed. Full HTML documents keep their restrictive CSP; fragments are wrapped with no scripts or network access.

Only `left_click` is supported. An `.html` file displays a native webview; a `.js` file runs as an async renderer function with `context.item`, `context.section`, `context.open(id)`, `context.executeCommand(command, ...args)`, `context.request(message)`, and `context.refresh()`. `context.section` is set only for section-button scripts. Scripts are trusted UI code: they have renderer access but no launcher Node API and no daemon secret. Compilation goes through the existing CDP transport without weakening Trusted Types.

## Bridge

Pages talk to the daemon through a token-authenticated loopback endpoint owned by the launcher. The injected runtime receives the endpoint URL and a random token and forwards each `acquireVsCodeApi()` message to it; the launcher holds the daemon client capability and performs every file write. Capabilities never reach a page, a webview, or a log.

| Action | Effect |
| --- | --- |
| `getAction` | Validated lazy HTML or JS source. |
| `runScript` | Runs the requesting attached window's script. |
| `reloadUi` | Reloads the definition and assets. |
| `getState` | Profiles and the workspace's sessions, for pages that need both. |
| `getProfiles`, `createProfile` | `GET`/`POST /api/profiles`. |
| `getRooms`, `createRoom` | `GET`/`POST /api/rooms`. |
| `getEvents`, `acknowledgeEvents` | Unread events for a profile. |
| `getSchedules`, `createSchedule`, `removeSchedule`, `refreshSchedules` | Schedule management. |
| `getPolicy` | The parsed workspace policy. |
| `getSettings`, `saveSettings` | Launcher settings. |
| `getDaemon`, `saveDaemon` | Daemon YAML. |
| `editConfig`, `editPolicy` | Open the daemon configuration or the workspace policy in Desktop. |

Unknown actions return HTTP 400; a wrong or missing bridge token returns HTTP 403.

## Settings and control socket

`~/.config/autonom/launcher.yml` holds the launcher's own values: `port` (daemon loopback port, default 8080), `configFile` (daemon YAML, default `~/.config/autonom/config.yml`), and `commandCenterConfig` (definition, default `assets/ui.yml`). `AUTONOM_PORT` and `AUTONOM_CONFIG` override the file, and the Settings page edits them through the bridge.

The launcher serves `$XDG_RUNTIME_DIR/autonom/launcher.sock` with mode 0600 — a private same-user channel for inspection, never a network endpoint:

```sh
node devin/launcher/cdp/control.mjs status
node devin/launcher/cdp/control.mjs targets
node devin/launcher/cdp/control.mjs eval <target> "globalThis.__autonomCenter.status()"
node devin/launcher/cdp/control.mjs screenshot <target> /tmp/autonom.png
node devin/launcher/cdp/control.mjs hot
node devin/launcher/cdp/control.mjs detach
```

`hot` re-reads the definition, asset versions, CSS, and the runtime bundle; a changed runtime is reinstalled. `detach` disposes the runtime and restores native Desktop. Control evaluations and screenshots release their temporary CDP sessions, and `status` reads the live renderer rather than cached state.

## Build

```sh
npm --prefix devin ci
npm --prefix devin run check
npm --prefix devin test
npm --prefix devin run build      # repository-root dist/launcher.js and dist/runtime.js
```

Install with `sudo python3 devin/install.py --no-build` after building as your normal user, quit Desktop once, then run `devin-desktop`. `python3 devin/install.py --check` verifies status; `--uninstall` restores the CLI shim byte-for-byte. `--app <resources/app>` selects a non-default installation.

Unit tests cover configuration validation and path confinement, overlay immutability and descriptor rollback, provider-mode restoration, pipe framing, CDP session scoping and capture, bridge authorization, launcher settings, the control socket, and the sidebar runtime. They never close a live gate.

## Live validation

A test may observe and operate real controls; it may never synthesize the surface it claims to validate. If the product does not render it, the run fails. Unit coverage proves a module, not an integration, and a screenshot is evidence only beside the DOM or state assertions that explain it. Never weaken a control to obtain a green run: no disabling the integrity service, rewriting checksums, loosening CSP, test-only vendor patches, or mutated profile data.

| Layer | Proves | Does not prove |
| --- | --- | --- |
| `npm run check` | Types and API shape compile | Runtime behavior |
| `npm test` | Pure logic and fail-closed guards | Desktop integration |
| Live launcher run | The built launcher attaches to the installed Desktop | Anything outside the tested build |
| Negative run | Hostile or malformed input fails closed | Happy-path correctness |

A release needs all four.

### Procedure

1. **Preconditions.** Desktop 1.126.0 at the pinned commit and hash; no unmanaged Desktop window already running; the repository `assets/` present; no concurrent change to the user data directory. Record the baseline first: `pgrep -af devin-desktop`, the workbench bundle SHA-256, and `git status --short`.
2. **Build and launch.** `npm ci && npm run check && npm test` in `devin/`, then `node dist/launcher.js <workspace>`, or `sudo python3 devin/install.py --no-build`, quit Desktop, and `devin-desktop --debug` for installed validation. Do not copy the user-data directory to get a clean run.
3. **Observe.** Through the control socket, assert `status` reports the expected `mode`, `enabled`, `revision`, and item labels; the Pages list contains the configured rows and excludes hidden ones; the custom webview is present with native content hidden while active; and default pipe mode exposes no DevTools listener.
4. **Drive real controls.** Click the on-screen switch (never set state programmatically) and assert Autonom shows the configured labels, Devin Cloud restores native labels and removes the custom page, and switching back needs no reload. Repeat for three cycles.
5. **Reload without restarting.** Edit a page, run `control.mjs hot`, and confirm the new content renders in the same window.
6. **Negative checks.** Invalid YAML, unknown imports, unsupported actions, duplicate IDs, symlinks, and traversal are refused before Desktop spawns, with the last valid state kept on `hot`. A wrong build is refused. A second launcher delegates its window request instead of taking the socket. A bad bridge token is 403 and an unknown action is 400. Killing the launcher lets the 30-second lease remove the wrappers.
7. **Integrity.** Confirm only the shim, its byte-for-byte backup, and the copied payload changed the installation. Investigate any integrity warning; never suppress it.
8. **Clean up.** `control.mjs detach`, verify native navigation returns, then stop the launcher. Desktop keeps running without the overlay.

Never click or navigate the communication window. Open a separate test window, identify it through `control.mjs targets`, and drive only that target:

```sh
AUTONOM_TEST_TARGET=<target> npm --prefix devin run test:integration
```

Record the Desktop version, commit, and bundle hash; the launcher command and exact control-socket calls with raw output; screenshot paths per state; and pass/fail per assertion. Store raw output rather than a summary — a claim without a captured artifact did not happen.

## Reading more

- [Sessions](SESSIONS.md) — the daemon the bridge talks to.
- [Coordination](COORDINATION.md) — the rooms and profiles this sidebar lists.
- [Daemon architecture](DAEMON.md) — capabilities, configuration, and deployment.