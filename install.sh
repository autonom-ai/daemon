#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
case " $* " in
    *" --uninstall "*|*" --check "*|*" --no-build "*|*" --help "*) ;;
    *)
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
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description="Install the Autonom launcher as the Devin Desktop CLI entrypoint.")
parser.add_argument("repository", type=Path)
parser.add_argument("--app", type=Path, default=Path("/usr/share/devin-desktop/resources/app"))
parser.add_argument("--no-build", action="store_true")
action = parser.add_mutually_exclusive_group()
action.add_argument("--uninstall", action="store_true")
action.add_argument("--check", action="store_true")
args = parser.parse_args()
app = args.app.resolve(strict=True)
desktop = app.parent.parent
payload = desktop / "autonom"
record = payload / "install.json"
entrypoint = desktop / "bin/devin-desktop"
backup = Path(str(entrypoint) + ".autonom.orig")
package = app / "package.json"


def read(path):

    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"Refusing a symlink or non-regular installation file: {path}")
    return path.read_bytes()


def digest(content):

    return hashlib.sha256(content).hexdigest()


def write(path, content, mode=0o644):

    if path.exists() or path.is_symlink():
        read(path)
    path.parent.mkdir(parents=True, exist_ok=True)
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


metadata = json.loads(read(package))
if metadata.get("version") != "1.126.0" or metadata.get("main") != "./out/main.js":
    raise SystemExit("Unsupported Desktop entrypoint or version; no installation files changed.")
product = json.loads(read(app / "product.json"))
if product.get("commit") != "fcf7ba39e6150055fad817f8716385b4d320d46d":
    raise SystemExit("Unsupported Desktop commit; no installation files changed.")
if digest(read(app / "out/vs/workbench/workbench.desktop.main.js")) != (
    "da45742ddd56f8d83e38c4c4a57802ffe4b6cc98645a787588eda346d455f22d"
):
    raise SystemExit("Desktop's workbench is not pristine; no installation files changed.")
saved = json.loads(read(record)) if record.exists() else None
installed = False
if backup.exists():
    original_entrypoint = read(backup)
    current_entrypoint = read(entrypoint)
    if not saved or saved.get("originalHash") != digest(original_entrypoint):
        raise SystemExit("Autonom's original CLI backup changed externally; refusing to overwrite it.")
    if digest(current_entrypoint) not in (saved.get("originalHash"), saved.get("stubHash")):
        raise SystemExit("The Devin Desktop CLI changed outside Autonom; refusing to overwrite it.")
    installed = digest(current_entrypoint) == saved.get("stubHash")
else:
    current_entrypoint = read(entrypoint)

if args.check:
    if installed:
        print("Autonom launcher installed.")
    else:
        print("Pristine Devin Desktop CLI; Autonom launcher not installed.")
elif args.uninstall:
    if backup.exists():
        write(entrypoint, read(backup), backup.stat().st_mode & 0o777)
    print("Restored the Devin Desktop CLI byte-for-byte. Original backups and inert launcher files retained.")
else:
    repository = args.repository.resolve(strict=True)
    node = shutil.which("node")
    files = [
        "dist/launcher.js",
        "dist/runtime.js",
        "source/launcher/cdp.mjs",
        "source/launcher/acp/server.py",
        "source/mcp/hook.py",
        "source/mcp/orchestrate.py",
        "source/mcp/server.py",
        "bin/autonom-daemon",
    ]
    for directory in ["assets", "templates"]:
        files.extend(str(path.relative_to(repository)) for path in (repository / directory).rglob("*")
                     if path.is_file() and "__pycache__" not in path.parts)
    if not node or any(not (repository / file).is_file() for file in files):
        raise SystemExit("Build the launcher and daemon and make Node available before installing.")
    node = subprocess.check_output([node, "-p", "process.execPath"], text=True).strip()
    stub = ("#!/bin/sh\nexec " + shlex.quote(node) + " "
            + shlex.quote(str(payload / "dist/launcher.js")) + ' "$@"\n').encode()
    next_record = {"originalHash": digest(read(backup if backup.exists() else entrypoint)), "stubHash": digest(stub)}
    try:
        for file in files:
            source = repository / file
            write(payload / file, read(source), source.stat().st_mode & 0o777)
        write(record, json.dumps(next_record, indent=2).encode() + b"\n")
        if not backup.exists():
            entrypoint.rename(backup)
        write(entrypoint, stub, 0o755)
    except PermissionError:
        raise SystemExit("Installation is read-only. After building as your normal user, run: sudo bash install.sh --no-build")
    print(f"Installed Autonom launcher in {payload}.")
    print("Quit Desktop once, then run devin-desktop. Arguments and terminal output are unchanged from node dist/launcher.js.")
    print("Rollback: bash install.sh --uninstall (use the same --app path and permissions).")
PY
