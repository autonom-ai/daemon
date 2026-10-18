# Native patches

Patches behave as small native hooks. Each module identifies the element or
method it borrows, owns its mutations, and restores them when its lifetime ends.
Domain configuration and bridge logic remain outside `launcher/patches/`.

| Patch | Native hook | Source | Contract |
| --- | --- | --- | --- |
| Command Center | Manifest getter, surface controller, sidebar rows, native webview/history | `patches/center/` | [Command Center](COMMAND_CENTER.md) |
| Workspace mode switch | `.agent-editor-switch`, native Agent/Editor buttons | `patches/mode-switch.ts` | [Mode switch](MODE_SWITCH.md) |
| ACP icons | React-owned provider icon hosts and session codicons | `patches/icons/` | [ACP icons](ACP_ICONS.md) |
| Service capture | Two native React snapshot callbacks, temporary debugger breakpoints | `patches/capture.ts` | [Service capture](CAPTURE.md) |
| Installed CLI shim | `bin/devin-desktop` on disk | `devin/install.py` | [Installer](../INSTALLER.md) |

## Shared lifecycle

`patches/lifecycle.ts` saves exact own descriptors, absent properties, CSS values
and priorities, attributes, and Map membership separately from its value. A
scope retains the first original and its latest owned value. Teardown runs in
reverse order, once, and continues after a failed cleanup. It restores only state
still owned by that patch; newer native/foreign replacements survive.

Static child scopes use `own`; transient element scopes remain in bounded live
maps and aggregate restoration without retaining detached DOM nodes. Modules
must register cleanup as resources are acquired and roll back partial installs.
Custom elements, listeners, subscriptions, observers and timers have explicit
owners. Do not create another independent save/restore mechanism outside this
boundary.

The renderer reports each named hook as `installed`, `restored`, `skipped` (a
foreign replacement was preserved), or `failed`. Service capture reports its
short-lived acquisition separately. Logs record transitions;
`node devin/launcher/cdp/control.mjs status` lists live hooks, installer provenance,
and the last detached-window restoration report. The installer report observes
the shim and its byte-for-byte backup; it never applies a disk mutation.

Hot replacement captures and validates native services before disposing the old
runtime. Detach and a 30-second heartbeat lease use the same restoration path.
Named diagnostic records are bounded by the hook catalog, not by render count.

## Compatibility

All hooks require the [pinned native build](COMMAND_CENTER.md#pin). A private
method, field, DOM role, or React ownership change requires renewed inspection
and live validation. Do not bypass integrity, alter vendor bundles/CSP/profile
data, or substitute synthetic DOM for a native acceptance test.

For each patch, preserve raw status, DOM/native-state assertions, screenshots,
and integrity/registry hashes from a separate controlled window. Pure lifecycle
and transport tests cover failure mechanics; they do not prove native rendering.
