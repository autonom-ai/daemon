#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
case " $* " in
    *" --uninstall "*|*" --check "*|*" --no-build "*|*" --help "*) ;;
    *)
        if [[ "$EUID" -ne 0 ]]; then
            (cd "$root" && dub build --compiler=ldc2 --config=daemon && dub build --compiler=ldc2 --config=relay)
            npm --prefix "$root/source/launcher" ci
            npm --prefix "$root/source/launcher" run check
            npm --prefix "$root/source/launcher" run build
        elif [[ ! -f "$root/dist/launcher.js" || ! -f "$root/dist/build.js" \
             || ! -d "$root/source/launcher/node_modules" \
             || ! -f "$root/bin/autonom-daemon" || ! -f "$root/bin/autonom-acp" ]]; then
            printf '%s\n' "Build the daemon, relay, and launcher as your normal user first: dub build --compiler=ldc2 --config=daemon && dub build --compiler=ldc2 --config=relay && npm --prefix source/launcher ci && npm --prefix source/launcher run build" >&2
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
archive_root = payload / "tracked-builds"
entrypoint = desktop / "bin/devin-desktop"
backup = Path(str(entrypoint) + ".autonom.orig")
repository = args.repository.resolve(strict=True)
verifier = repository / "dist" / "build.js"


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


def is_hex(value):

    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def require_node():

    node = shutil.which("node")
    if not node:
        raise SystemExit("Node 22+ is required to verify the Desktop build.")
    try:
        out = subprocess.run([node, "--version"], capture_output=True, text=True, timeout=10)
        major = int(out.stdout.strip().lstrip("v").split(".")[0])
    except (OSError, subprocess.SubprocessError, ValueError):
        major = 0
    if major < 22:
        raise SystemExit("Node 22+ is required to verify the Desktop build.")
    return node


def verify_build(node):

    if not verifier.is_file():
        raise SystemExit("The Autonom build verifier is missing. Run npm --prefix source/launcher run build.")
    out = subprocess.run([node, str(verifier), str(app)], capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise SystemExit(out.stderr.strip() or "Desktop build verification failed; no installation files changed.")
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        raise SystemExit("The build verifier returned malformed output; no installation files changed.")


def package_expected(node, path):
    """The owning package's recorded digest for path, or None when unverifiable."""
    if not verifier.is_file():
        return None
    try:
        out = subprocess.run([node, str(verifier), "--file", str(path)],
                             capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    try:
        result = json.loads(out.stdout)
    except json.JSONDecodeError:
        return None
    expected = result.get("expected")
    return expected if isinstance(expected, str) else None


def load_record():

    if record.is_symlink() or (record.exists() and not record.is_file()):
        raise SystemExit("Refusing a symlink or non-regular installation record.")
    if not record.exists():
        return None
    saved = json.loads(read(record))
    if not isinstance(saved, dict):
        raise SystemExit("Unrecognized Autonom installation record.")
    if saved.get("version") == 2:
        build, cli = saved.get("build"), saved.get("cli")
        if not isinstance(build, dict) or not isinstance(cli, dict):
            raise SystemExit("Malformed Autonom installation record.")
        if not is_hex(cli.get("originalHash")) or not is_hex(cli.get("stubHash")) \
                or cli.get("backupPath") != str(backup):
            raise SystemExit("Malformed Autonom installation record.")
        return {"version": 2, "build": build, "cli": cli, "raw": saved}
    if is_hex(saved.get("originalHash")) and is_hex(saved.get("stubHash")):
        return {"version": 1, "build": None,
                "cli": {"originalHash": saved["originalHash"], "stubHash": saved["stubHash"]},
                "raw": saved}
    raise SystemExit("Unrecognized Autonom installation record.")


node = require_node()
identity = verify_build(node)
saved = load_record()
current = digest(read(entrypoint))
tracked = saved["cli"] if saved else None
expected_cli = package_expected(node, entrypoint)
backup_bytes = None
if backup.is_symlink() or (backup.exists() and not backup.is_file()):
    raise SystemExit("Refusing a symlink or non-regular CLI backup.")
if backup.exists():
    backup_bytes = read(backup)
    if not saved:
        raise SystemExit("An Autonom CLI backup exists without an installation record.")
    if digest(backup_bytes) != tracked["originalHash"]:
        raise SystemExit("Autonom's original CLI backup changed externally; refusing to overwrite it.")
if saved and saved["version"] == 1 \
        and (backup_bytes is None or current not in (tracked["originalHash"], tracked["stubHash"])):
    raise SystemExit("The legacy installation record does not match the current CLI state; refusing to migrate it.")

known = saved is not None and current in (tracked["originalHash"], tracked["stubHash"])
genuine = expected_cli is not None and current == expected_cli
foreign = saved is not None and not known and not genuine
same_generation = saved is not None and (
    saved["version"] == 1 and identity.get("source") == "pin"
    or saved["version"] == 2 and saved["build"].get("workbenchHash") == identity.get("workbenchHash"))


def build_line():

    if identity.get("source") == "package":
        return f"Desktop build {identity['version']} ({identity['commit'][:12]}) verified against package {identity.get('packageId', 'unknown')}."
    return f"Desktop build {identity['version']} ({identity['commit'][:12]}) matches the verified pin."


if args.check:
    print(build_line())
    if not saved:
        if genuine:
            print("Pristine Devin Desktop CLI; Autonom launcher not installed.")
        else:
            print("Unrecognized Devin Desktop CLI; Autonom launcher not installed.")
    elif current == tracked["stubHash"]:
        print("Autonom launcher installed.")
        if not same_generation:
            print("The Desktop build changed since installation; reinstall to re-track this build.")
    elif current == tracked["originalHash"]:
        print("The vendor Devin Desktop CLI is in place; the Autonom wrapper is not active.")
        print("An official update likely reverted it; run bash install.sh to reinstall.")
    elif genuine:
        print("An official Desktop update replaced the CLI; run bash install.sh to reinstall.")
    else:
        print("The Devin Desktop CLI changed outside Autonom; refusing to touch it.")
elif args.uninstall:
    if not saved:
        print("Autonom launcher is not installed; nothing to restore.")
    elif foreign:
        raise SystemExit("The Devin Desktop CLI changed outside Autonom; refusing to overwrite it.")
    elif current == tracked["stubHash"]:
        if not same_generation and (expected_cli is None or digest(backup_bytes) != expected_cli):
            raise SystemExit("The CLI backup belongs to a previous Desktop build; refusing to restore it.")
        write(entrypoint, backup_bytes, backup.stat().st_mode & 0o777)
        print("Restored the Devin Desktop CLI byte-for-byte. Original backups and inert launcher files retained.")
    else:
        print("The Devin Desktop CLI is already the vendor original; nothing to restore.")
else:
    if foreign:
        raise SystemExit("The Devin Desktop CLI changed outside Autonom; refusing to overwrite it.")
    files = [
        "dist/launcher.js",
        "dist/runtime.js",
        "source/launcher/cdp.mjs",
        "source/daemon/interop/devin/hook.py",
        "source/mcp/server.py",
        "bin/autonom-daemon",
        "bin/autonom-acp",
    ]
    for directory in ["assets", "templates"]:
        files.extend(str(path.relative_to(repository)) for path in (repository / directory).rglob("*")
                     if path.is_file() and "__pycache__" not in path.parts)
    if any(not (repository / file).is_file() or (repository / file).is_symlink() for file in files):
        raise SystemExit("Build the daemon, relay, and launcher and make Node available before installing.")
    node_path = subprocess.check_output([node, "-p", "process.execPath"], text=True).strip()
    stub = ("#!/bin/sh\nexec " + shlex.quote(node_path) + " "
            + shlex.quote(str(payload / "dist/launcher.js")) + ' "$@"\n').encode()
    original_hash = tracked["originalHash"] if known else current
    next_record = {
        "version": 2,
        "build": identity,
        "cli": {"originalHash": original_hash, "stubHash": digest(stub), "backupPath": str(backup)},
    }
    moved = False
    try:
        for file in files:
            source = repository / file
            write(payload / file, read(source), source.stat().st_mode & 0o777)
        if saved and saved["raw"] != next_record:
            archive = archive_root / digest(json.dumps(saved["raw"], sort_keys=True).encode())
            write(archive / "install.json", json.dumps(saved["raw"], indent=2).encode() + b"\n")
            if backup_bytes is not None:
                write(archive / "devin-desktop.orig", backup_bytes)
        if not backup.exists() or not known:
            os.replace(entrypoint, backup)
            moved = True
        write(entrypoint, stub, 0o755)
        write(record, json.dumps(next_record, indent=2).encode() + b"\n")
    except PermissionError:
        if moved and not entrypoint.exists() and backup.exists():
            try:
                os.replace(backup, entrypoint)
            except OSError:
                pass
        raise SystemExit("Installation is read-only. After building as your normal user, run: sudo bash install.sh --no-build")
    except OSError as error:
        if moved and not entrypoint.exists() and backup.exists():
            try:
                os.replace(backup, entrypoint)
            except OSError:
                pass
        raise SystemExit(f"Installation failed: {error}")
    print(f"Installed Autonom launcher in {payload}.")
    print("Quit Desktop once, then run devin-desktop. Arguments and terminal output are unchanged from node dist/launcher.js.")
    print("Rollback: bash install.sh --uninstall (use the same --app path and permissions).")
PY
