# Devin Desktop Command Center adapter

## Status and safety model

The extension is now `cet.autonom-command-center` version `0.5.2`. It adapts Devin Desktop **1.126.0** at runtime; it does not alter Desktop JavaScript, HTML, CSP, `product.json`, checksums, or the Devin profile data directory. The adapter is deliberately pinned to one inspected build and refuses to attach when its commit or native host bundle differs.

Devin's native integrity check remains authoritative. On Desktop 1.126.0 only, the adapter dismisses the visible corruption toast only when it verifies the exact historical Autonom 0.4.0 residue: exactly three product-checksum mismatches with the known old patched hashes; a pristine native host bundle; and `product.checksums.orig.json` plus the restored workbench/chat/sessions files all matching the recorded pristine hashes. Any extra, missing, unknown, or changed mismatch fails this test and leaves the native toast visible. This dismisses only the exact toast through Devin's normal Clear Notification action in the current window. It does not mark the installation pure, write `integrityService` storage, change `product.json`, or modify any Desktop/user-data files. The checked proof and suppression state are attached to this extension activation and are revalidated on configuration reload; a newly modified build that fails the native-host pin will not attach, let alone hide its warning.

The previous `cet.autonom` extension (`0.4.0`) is a separate, legacy implementation which edits installed bundles and `product.json`. Do not enable it alongside this runtime adapter. This build has a distinct extension ID and does not migrate, remove, or rewrite the old extension's files or its historical backups. It does not delete old `autonom.*` files in Desktop's installation.

## Verified native boundaries

The inspected page-list and active-surface pipeline is:

1. The workbench passes `subscribeToDesktopNavSurfaces` and `getDesktopNavSurfacesSnapshot` into the agent sidebar React context.
2. The native navigation manifest service owns the items `{id, path, icon, label}`. Its `updateManifest` writes application storage, so the adapter does **not** call it.
3. `devin.desktopNav.openSurface` selects a surface and opens the native Agent view.
4. A separate native surface controller mounts the page webview in the `windsurf-nav-surface-layer`. `ewt` is a performance/telemetry component; it is not the content pane.

The adapter temporarily wraps the in-memory manifest getter and the current window's native surface controller. It keeps a stable, cached overlay snapshot, notifies the native manifest event, and leaves React responsible for rendering its original navigation. Selecting an Autonom item calls the existing native `devin.desktopNav.openSurface` command.

Custom HTML is placed in a separate native Electron webview over that controller's existing page mount. The existing remote webview stays mounted and is hidden only while a custom page is active; no native sidebar siblings, chat, composer, or other native page are hidden. Custom webviews have `allowScripts: false`, `allowForms: false`, no local resource roots, and a `default-src 'none'` CSP. A heartbeat removes runtime wrappers if the extension host disappears. Disable and deactivation restore captured property descriptors and the original navigation state.

The test run observed two brief CDP debugger pauses while it captured the private native references during first attachment. Normal config reloads use the already-captured references and do not pause the renderer again. CDP is loopback-only, target URLs and socket hosts are validated, and a random command identity binds attachment to exactly one window. No auth token or capability is serialized to a webview or an output log.

### Pin for Desktop 1.126.0

- Product commit: `fcf7ba39e6150055fad817f8716385b4d320d46d`
- Native host bundle: `out/vs/workbench/workbench.desktop.main.js`
- SHA-256: `da45742ddd56f8d83e38c4c4a57802ffe4b6cc98645a787588eda346d455f22d`
- Build: `1.126.0`, Devin Desktop / Windsurf `3.10.48`

These references point into minified private implementation details, not a supported Desktop extension API. A version, commit, hash, API-shape, or React-boundary change must fail closed and be re-researched before extending the pin. Do not replace the pin with a loose DOM heuristic.

## Native visual language

The sidebar uses native structural roles:

- `ul[data-slot="sidebar-menu"]` contains `li[data-slot="sidebar-menu-item"]` entries.
- `div[data-slot="sidebar-menu-button"]` is the native 30px menu surface with its active state in `data-active`.
- `button[aria-label="New session"]` identifies the real New session row.
- The primary page list has `aria-label="Pages"`; visible rows carry an accessible `aria-label` matching the page label.
- `data-slot="sidebar-button-content"` / `data-slot="sidebar-menu-button-content"` style the icon-and-label interior.

The toggle intentionally reuses Devin's inspected `.agent-editor-switch`, `.switch-container`, `.switch-segment`, `.segment-label`, and `.active` classes. These native rules supply the 24px height, 12px/500 font, 10px horizontal padding, 7px radius, title-bar foreground, tint-secondary track, active elevated background, and dark/high-contrast border. Both segments explicitly use `flex: 1 1 0` and `min-width: 0`, yielding equal widths. The selected segment overlays the native active fill with `rgb(var(--bg-accent-primary))` and uses `--vscode-button-foreground`; the unselected segment remains transparent. Devin 1.126 resolves the accent to `0 120 212` in the inspected dark theme. Use `classList.toggle("active", isActive)`, `aria-pressed`, and an accessible name; don't draw replacement icons or inject broad CSS. The row inherits the native menu-item class and is inserted immediately before New session. Its small mutation observer watches for React replacing that one menu item and restores only the toggle row.

Useful pinned theme tokens include `--text-primary`, `--text-secondary`, `--tint-secondary`, `--bg-elevated-transparent`, `--border-secondary`, and `--vscode-titleBar-activeForeground`. Prefer Devin's existing Bootstrap icon names and design-token rules over hard-coded colors or a second icon library. Native theme values and CSS rules are generated in the installed `out` assets; treat them as version-pinned observations, not a stable public API.

The actual native page-item data contract is `{id, path, label, icon}` (Desktop may add fields such as `beta` and `render`). Preserve unknown native fields and do not mutate native item objects. Custom config IDs use lowercase ASCII letters, digits, and hyphens. A visible custom page item maps to `/autonom/<tab-id>`; its matching native surface keeps the original ID, so React's page activation and accessible label remain native.

## Workspace files

The starting example is committed in the repository's `.devin/` directory:

- `commandCenter.json` describes visible pages and provider mode.
- `hello.html` replaces the Automations content in the example.
- `notes.html` supplies an additional page.

Configuration is opt-in and does not attach on extension startup. For a trusted workspace, run **Autonom Command Center: Attach**; its default file is `<workspace>/.devin/commandCenter.json`. The command takes an optional absolute config path. **Reload Configuration** re-reads and validates the full config and every page file before applying anything. Editing files has no visible effect until reload. The test window uses the already-logged-in Devin profile but stores none of this configuration under Desktop's application data directory.

Example:

```json
{
    "enabled": true,
    "items": [
        { "id": "automations", "label": "Jared", "tab": "hello" },
        { "id": "security", "hidden": true },
        { "id": "notes", "label": "Notes", "icon": "wiki", "tab": "notes" }
    ],
    "tabs": {
        "hello": { "title": "Hello world", "file": "hello.html" },
        "notes": { "title": "Notes", "file": "notes.html" }
    },
    "activeTab": "hello"
}
```

A native item is renamed by its exact manifest `id`; `{ "id": "security", "hidden": true }` removes a native row for Autonom mode only. A custom item needs a `tab`; a native item with no `tab` keeps its original native `path` and content. The Autonom/Devin Cloud toggle is transient per attached window. Devin Cloud mode returns the original native manifest and shows the original native surface. The configuration remains loaded, so selecting Autonom restores its configured overlay without restarting Desktop.

Config rules:

- A trusted workspace is required; there is no automatic attach or automatic creation of configuration files.
- `enabled` must be boolean. `items` and `tabs` are capped at 100 entries each; IDs are capped at 64 ASCII characters.
- Each page file is a regular no-follow file beneath the directory containing `commandCenter.json`, capped at 256 KiB. All page content combined is capped at 1 MiB. Titles are capped at 200 characters.
- Invalid JSON, invalid schema, duplicate IDs, unknown tab references, symlinks, and path traversal reject the complete reload; the last valid native snapshot remains active.
- Page contents are trusted workspace-authored HTML fragments; their renderer is nevertheless script-, form-, and network-disabled. Do not weaken the CSP or enable remote resources to make a page work.

## Commands and workflow

- **Attach**: validate and read the config, open the native all-sessions/Agent view only when needed, identify this extension activation's exact renderer, then apply the runtime overlay.
- **Reload Configuration**: re-read the selected config and referenced HTML and update the existing native runtime without another debugger pause.
- **Disable**: disconnect the adapter and restore native manifest/controller descriptors.
- **Show Native Status**: report bounded IDs, labels, paths, active tab, provider, revision, and window ID.
- **Open Tab**: open a configured custom surface through the native navigation command.
- **Edit Configuration**: open the workspace JSON file.

Package and verify from `extension/` with `npm run check`, `npm test`, `npm audit`, and `npm run package`. The output is `bin/autonom-command-center-0.5.2.vsix`; install/update with `devin-desktop --install-extension <path-to-vsix> --force`. The integration test uses a logged-in Desktop started with `devin-desktop --remote-debugging-port=9882 --disable-extension cet.autonom &`. Keep the old extension disabled; the separate `cet.autonom-command-center` ID avoids overwriting or activating it.

A genuine live acceptance run must install the packaged VSIX, use the registered `autonomCenter.*` extension-host commands against the target identified by the activation UUID, take CDP screenshots, and verify both Autonom and Devin Cloud views. Do not count direct `AutonomNative.install()` injection alone as extension installation validation. Do not patch the integrity service, rewrite checksums, change app CSP, or use isolated/mutated profile data to obtain a green test.
