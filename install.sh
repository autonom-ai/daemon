#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
case " $* " in
    *" --uninstall "*|*" --check "*|*" --no-build "*|*" --help "*) ;;
    *)
        node --check "$root/source/launcher/bootstrap.mjs"
        if [[ "$EUID" -ne 0 ]]; then
            npm --prefix "$root/source/launcher" ci
            npm --prefix "$root/source/launcher" run check
            npm --prefix "$root/source/launcher" run build
        elif [[ ! -f "$root/dist/launcher.js" || ! -d "$root/source/launcher/node_modules" ]]; then
            printf '%s\n' "Build as your normal user first: npm --prefix source/launcher ci && npm --prefix source/launcher run build" >&2
            exit 1
        fi
        ;;
esac

python3 - "$root" "$@" <<'PY'
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description="Install the Autonom startup bootstrap into Devin Desktop.")
parser.add_argument("repository", type=Path)
parser.add_argument("--app", type=Path, default=Path("/usr/share/devin-desktop/resources/app"))
parser.add_argument("--no-build", action="store_true")
action = parser.add_mutually_exclusive_group()
action.add_argument("--uninstall", action="store_true")
action.add_argument("--check", action="store_true")
args = parser.parse_args()
app = args.app.resolve(strict=True)
package = app / "package.json"
backup = app / "package.json.autonom.orig"
bootstrap = app / "out/autonom-bootstrap.mjs"
record = app / "out/autonom-install.json"


def read(path):

    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"Refusing a symlink or non-regular installation file: {path}")
    return path.read_bytes()


def digest(content):

    return hashlib.sha256(content).hexdigest()


def write(path, content, mode=0o644):

    if path.exists() or path.is_symlink():
        read(path)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


current = read(package)
original = read(backup) if backup.exists() else current
metadata = json.loads(original)
if metadata.get("version") != "1.126.0" or metadata.get("main") != "./out/main.js":
    raise SystemExit("Unsupported Desktop entrypoint or version; no installation files changed.")
product = json.loads(read(app / "product.json"))
if product.get("commit") != "fcf7ba39e6150055fad817f8716385b4d320d46d":
    raise SystemExit("Unsupported Desktop commit; no installation files changed.")
if digest(read(app / "out/vs/workbench/workbench.desktop.main.js")) != (
    "da45742ddd56f8d83e38c4c4a57802ffe4b6cc98645a787588eda346d455f22d"
):
    raise SystemExit("Desktop's workbench is not pristine; no installation files changed.")
anchor = b'"main": "./out/main.js"'
if original.count(anchor) != 1:
    raise SystemExit("Unknown package.json entrypoint format; no installation files changed.")
patched = original.replace(anchor, b'"main": "./out/autonom-bootstrap.mjs"', 1)
if current not in (original, patched):
    raise SystemExit("package.json was changed outside Autonom; refusing to overwrite it.")
installed = current == patched
if installed or bootstrap.exists() or record.exists():
    if not backup.exists():
        raise SystemExit("Existing bootstrap files have no original backup; refusing to overwrite them.")
    saved = json.loads(read(record))
    if saved.get("packageHash") != digest(original) or saved.get("bootstrapHash") != digest(read(bootstrap)):
        raise SystemExit("Autonom's backup or bootstrap was changed externally; refusing to overwrite it.")

if args.check:
    print("Autonom bootstrap installed." if installed else "Pristine Desktop entrypoint; Autonom not installed.")
elif args.uninstall:
    if installed:
        write(package, original, package.stat().st_mode & 0o777)
        print("Restored package.json byte-for-byte. Backup and inert bootstrap files retained.")
    else:
        print("Desktop already uses its original entrypoint.")
else:
    repository = args.repository.resolve(strict=True)
    launcher = repository / "dist/launcher.js"
    node = shutil.which("node")
    if not node or not launcher.is_file():
        raise SystemExit("Build the launcher and make Node available before installing.")
    content = read(repository / "source/launcher/bootstrap.mjs")
    config = json.dumps({
        "launcher": str(launcher),
        "node": subprocess.check_output([node, "-p", "process.execPath"], text=True).strip(),
        "packageHash": digest(original),
        "bootstrapHash": digest(content),
    }, indent=2).encode() + b"\n"
    try:
        if not backup.exists():
            with backup.open("xb") as output:
                output.write(original)
                output.flush()
                os.fsync(output.fileno())
            os.chmod(backup, package.stat().st_mode & 0o777)
        write(bootstrap, content)
        write(record, config)
        write(package, patched, package.stat().st_mode & 0o777)
    except PermissionError:
        raise SystemExit("Installation is read-only. After building as your normal user, run: sudo bash install.sh")
    print(f"Installed Autonom bootstrap in {app}.")
    print("Quit Desktop once, then launch it normally. The existing profile and login are preserved.")
    print("Launcher logs: ~/.cache/autonom/launcher.log (or $XDG_CACHE_HOME/autonom/launcher.log).")
    print("Rollback: bash install.sh --uninstall (use the same --app path and permissions).")
PY
