# Launcher installation

`devin/install.py` performs a transactional installation beside the verified
Desktop directory. Its only vendor disk patch replaces `bin/devin-desktop`
with a launcher shim. It keeps the original byte-for-byte as
`bin/devin-desktop.autonom.orig` and copies Autonom binaries, bundles and assets
into the sibling `autonom/` payload. `install.json` records the build, shim hash,
original hash and backup path. This shim is also listed in the
[native patch catalog](patches/README.md).

The Electron executable, entrypoint, vendor bundles, checksums, `product.json`,
CSP and user profile remain untouched. The launcher verifies the pinned build
before starting Desktop; package provenance is checked where applicable. A
missing or mismatched recorded backup blocks replacement/removal rather than
replacing uncertain state.

## Install and inspect

Build as the normal user, then copy the reviewed payload with elevated
permissions only when the installation requires it:

```sh
dub build --compiler=ldc2 --config=daemon
dub build --compiler=ldc2 --config=relay
npm --prefix devin ci
npm --prefix devin run check
npm --prefix devin test
sudo python3 devin/install.py --no-build
python3 devin/install.py --check
```

`python3 devin/install.py` builds and installs in one invocation for a writable
installation. `--app <resources/app>` selects another installation. Restart
Desktop through `devin-desktop --debug` verbatim for controlled live validation;
a forwarded window in an existing unmanaged browser cannot acquire a new
private debugging pipe. Never use copied profile directories for tests.

At launch, the `installer.cli-shim` status observes the installed shim and backup
hashes against the matching installation record. `control.mjs status` includes
this provenance alongside renderer patches. A checkout launched without an
installation record reports that observation as skipped; it does not fabricate
an installed shim or change disk state.

## Rollback and removal

File replacements are transactional: failures roll back the files changed in
that attempt. Reinstallation keeps verified provenance and archives an older
build record when necessary. Removal verifies ownership and the recorded backup
before restoring the original shim:

```sh
sudo python3 devin/install.py --uninstall
```

Configuration, sessions, user data and file logs are preserved. Connector
registration/enabling is a separate launcher startup operation, not an installer
patch. Its icon metadata remains user-owned; icon conversion never writes it.
Installer safety tests use narrow temporary installation trees and ownership
fixtures, while installed-build integration tests read the actual installation.
