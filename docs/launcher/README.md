# Launcher

`devin/launcher/app.ts` starts the verified Desktop build, connects the daemon,
serves an authenticated loopback page bridge, and attaches native patches through
CDP. The default transport is a private debugging pipe; `devin-desktop --debug`
opens a loopback development endpoint. Further launches delegate window requests
to the managed instance.

- [Installation](INSTALLER.md): copied payload, the one disk shim patch, provenance,
  package checks, rollback, and removal.
- [Patches](patches/README.md): native hook modules, installation/restoration,
  diagnostics, and compatibility gates.
- [Command Center](patches/COMMAND_CENTER.md): configuration, page actions,
  bridge, private native contract, and live validation.

## Ownership

| Source | Owns |
| --- | --- |
| `launcher/app.ts` | Startup, hot reload, shutdown, settings and control socket. |
| `launcher/desktop/` | Desktop process/environment and build verification. |
| `launcher/cdp/` | Transport, scoped sessions, and operator control protocol. |
| `launcher/center/` | Configuration, action sources, directory data, and bridge. |
| `launcher/patches/` | Native captures, element hooks, runtime patches and exact restoration. |
| `launcher/acp/registry.ts` | Connector registration/enabling and read-only icon metadata discovery. |
| `assets/` | Configured pages, scripts, styles and bundled marks. |

Connector registration remains a separate startup operation. Icon loading never
writes the registry or settings. It reads every provider's `icon`, caches Base64
assets in Node, and sends a provider dictionary to the renderer.

Build and test as the normal user:

```sh
npm --prefix devin ci
npm --prefix devin run check
npm --prefix devin test
npm --prefix devin run test:integration
```

The integration suite reads the real installation. With `AUTONOM_TEST_TARGET`
it also operates the explicitly selected, separately opened Desktop window;
see the [live procedure](patches/COMMAND_CENTER.md#live-validation).
