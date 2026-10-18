# Native service capture

`patches/capture.ts` observes the pinned sidebar's React context for
`getDesktopNavSurfacesSnapshot` and `getActiveDesktopNavSurfaceSnapshot`.
Two short debugger pauses capture the manifest service, surface controller,
window groups, window ID and native command API. These references stay in the
renderer; pages receive only scoped bridge requests.

`patches/window.ts` orchestrates capture, bundle installation and diagnostics.
Loading a replacement bundle does not dispose the old UI. Native references are
captured and validated before the replacement runtime takes ownership; an absent
sidebar or failed recapture preserves the prior runtime and mode switch. The
cached icon dictionary survives a bundle replacement.

Every acquisition step is inside cleanup: probe globals disappear even when the
sidebar is absent; partial service globals disappear after failure; breakpoint
removal, resume, debugger disable and object-group release are independent.
Only a pause owned by this capture is resumed. Captured services are removed
from the scratch global after installation. Transport tests exercise every
failure stage, including timeout; live tests must also verify failed recapture
and normal hot replacement against the actual native build.

This hook is temporary: successful status is `restored` once debugger resources
are released. A failed attempt is reported separately from the still-installed
renderer hooks. No debugger or vendor integrity controls are disabled to make
the capture work.
