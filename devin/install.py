#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path


def read(path):
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"Refusing a symlink or non-regular installation file: {path}")
    return path.read_bytes()


def digest(content):
    return hashlib.sha256(content).hexdigest()


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


def verify_build(node, verifier, app):
    if not verifier.is_file():
        raise SystemExit("The Autonom build verifier is missing. Run npm --prefix devin run build.")
    out = subprocess.run([node, str(verifier), str(app)], capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise SystemExit(out.stderr.strip() or "Desktop build verification failed; no installation files changed.")
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        raise SystemExit("The build verifier returned malformed output; no installation files changed.")


def package_expected(node, path, verifier, identity):
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
    owner = result.get("packageId")
    if not isinstance(expected, str):
        return None
    if identity.get("packageId") and owner != identity.get("packageId"):
        return None
    return expected


def load_record(record, backup):
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


def build_line(identity):
    if identity.get("source") == "package":
        return f"Desktop build {identity['version']} ({identity['commit'][:12]}) verified against package {identity.get('packageId', 'unknown')}."
    return f"Desktop build {identity['version']} ({identity['commit'][:12]}) matches the verified pin."


class Installation:
    def __init__(self, desktop):
        self.desktop = desktop
        self.staged = []
        self.created = []
        self.created_dirs = []
        self.staged_paths = set()
        self.created_paths = set()
        self.staging = None

    def guard(self, path):
        for ancestor in (path, *path.parents):
            if ancestor == self.desktop:
                return
            if ancestor.is_symlink():
                raise SystemExit(f"Refusing to write through a symlinked path: {ancestor}")

    def stage(self, path):
        self.guard(path)
        if path in self.staged_paths or path in self.created_paths:
            return
        if self.staging is None:
            self.staging = Path(tempfile.mkdtemp(prefix=".autonom-rollback-", dir=self.desktop))
        if path.is_symlink():
            snap = self.staging / f"snap-{len(self.staged)}"
            os.symlink(os.readlink(path), snap)
            self.staged.append((snap, path))
            self.staged_paths.add(path)
        elif path.exists():
            snap = self.staging / f"snap-{len(self.staged)}"
            shutil.copy2(path, snap)
            self.staged.append((snap, path))
            self.staged_paths.add(path)
        else:
            self.created.append(path)
            self.created_paths.add(path)

    def rollback(self):
        for snap, path in reversed(self.staged):
            if os.path.lexists(snap):
                try:
                    os.replace(snap, path)
                except OSError:
                    pass
        for path in self.created:
            try:
                if os.path.lexists(path):
                    path.unlink()
            except OSError:
                pass
        for directory in self.created_dirs:
            shutil.rmtree(directory, ignore_errors=True)
        if self.staging is not None:
            shutil.rmtree(self.staging, ignore_errors=True)

    def finish(self):
        if self.staging is not None:
            shutil.rmtree(self.staging, ignore_errors=True)
            self.staging = None

    def write(self, path, content, mode=0o644):
        self.stage(path)
        parent = path.parent
        chain = []
        while not parent.exists() and parent != self.desktop:
            chain.append(parent)
            parent = parent.parent
        if chain:
            self.created_dirs.append(chain[-1])
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


def main():
    parser = argparse.ArgumentParser(description="Install the Autonom launcher as the Devin Desktop CLI entrypoint.")
    parser.add_argument("--app", type=Path, default=Path("/usr/share/devin-desktop/resources/app"))
    parser.add_argument("--no-build", action="store_true")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--uninstall", action="store_true")
    action.add_argument("--check", action="store_true")
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    if not (args.no_build or args.uninstall or args.check):
        if os.geteuid() == 0:
            raise SystemExit("Build as your normal user, then run sudo python3 devin/install.py --no-build.")
        subprocess.run(["dub", "build", "--compiler=ldc2", "--config=daemon"], cwd=repository, check=True)
        subprocess.run(["dub", "build", "--compiler=ldc2", "--config=relay"], cwd=repository, check=True)
        for command in (["ci"], ["run", "check"], ["run", "build"]):
            subprocess.run(["npm", "--prefix", str(repository / "devin"), *command], check=True)
    app = args.app.resolve(strict=True)
    desktop = app.parent.parent
    installation = Installation(desktop)
    payload = desktop / "autonom"
    record = payload / "install.json"
    archive_root = payload / "tracked-builds"
    entrypoint = desktop / "bin/devin-desktop"
    backup = Path(str(entrypoint) + ".autonom.orig")
    verifier = repository / "dist" / "build.js"

    node = require_node()
    identity = verify_build(node, verifier, app)
    saved = load_record(record, backup)
    current = digest(read(entrypoint))
    tracked = saved["cli"] if saved else None
    expected_cli = package_expected(node, entrypoint, verifier, identity)
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
    wrapper = saved is not None and current == tracked["stubHash"]
    same_generation = saved is not None and (
        saved["version"] == 1 and identity.get("source") == "pin"
        or saved["version"] == 2 and saved["build"] == identity)
    backup_is_packaged = backup_bytes is not None and expected_cli is not None \
        and digest(backup_bytes) == expected_cli

    if args.check:
        print(build_line(identity))
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
            print("An official update likely reverted it; run python3 devin/install.py to reinstall.")
        elif genuine:
            print("An official Desktop update replaced the CLI; run python3 devin/install.py to reinstall.")
        else:
            print("The Devin Desktop CLI changed outside Autonom; refusing to touch it.")
    elif args.uninstall:
        if not saved:
            print("Autonom launcher is not installed; nothing to restore.")
        elif foreign:
            raise SystemExit("The Devin Desktop CLI changed outside Autonom; refusing to overwrite it.")
        elif wrapper:
            if backup_bytes is None:
                raise SystemExit("The recorded CLI backup is missing; refusing to restore.")
            if not same_generation:
                if expected_cli is None:
                    raise SystemExit("The Desktop build changed and the packaged CLI cannot be proven; "
                                     "refusing to restore the recorded backup.")
                if not backup_is_packaged:
                    raise SystemExit("The CLI backup belongs to a previous Desktop build; refusing to restore it.")
            elif expected_cli is not None and not backup_is_packaged:
                raise SystemExit("The recorded CLI backup is not the packaged CLI for this build; "
                                 "refusing to restore it.")
            try:
                installation.write(entrypoint, backup_bytes, backup.stat().st_mode & 0o777)
                installation.finish()
            except SystemExit:
                installation.rollback()
                raise
            except OSError as error:
                installation.rollback()
                raise SystemExit(f"Uninstall failed: {error}")
            print("Restored the Devin Desktop CLI byte-for-byte. Original backups and inert launcher files retained.")
        else:
            print("The Devin Desktop CLI is already the vendor original; nothing to restore.")
    else:
        if foreign:
            raise SystemExit("The Devin Desktop CLI changed outside Autonom; refusing to overwrite it.")
        if wrapper:
            if backup_bytes is None:
                raise SystemExit("The recorded CLI backup is missing; refusing to reinstall over it.")
            if not same_generation:
                if expected_cli is None:
                    raise SystemExit("The Desktop build changed but the packaged CLI cannot be proven; "
                                     "refusing to touch the retained Autonom wrapper.")
                if not backup_is_packaged:
                    raise SystemExit("The recorded CLI backup is not the packaged CLI for this Desktop "
                                     "build; refusing to reuse it.")
            elif expected_cli is not None and not backup_is_packaged:
                raise SystemExit("The recorded CLI backup is not the packaged CLI for this Desktop "
                                 "build; refusing to reuse it.")
        elif saved and expected_cli is not None and tracked["originalHash"] != expected_cli:
            if same_generation or not genuine:
                raise SystemExit("The Devin Desktop CLI does not match the packaged bytes for this "
                                 "build; refusing to reuse stale vendor bytes.")
        files = [
            "dist/launcher.js",
            "dist/runtime.js",
            "devin/hooks.v1.json",
            "devin/launcher/cdp.mjs",
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
        original_hash = tracked["originalHash"] if known and not genuine else current
        next_record = {
            "version": 2,
            "build": identity,
            "cli": {"originalHash": original_hash, "stubHash": digest(stub), "backupPath": str(backup)},
        }
        try:
            for file in files:
                source = repository / file
                installation.write(payload / file, read(source), source.stat().st_mode & 0o777)
            if saved and saved["raw"] != next_record:
                archive = archive_root / digest(json.dumps(saved["raw"], sort_keys=True).encode())
                installation.write(archive / "install.json", json.dumps(saved["raw"], indent=2).encode() + b"\n")
                if backup_bytes is not None:
                    installation.write(archive / "devin-desktop.orig", backup_bytes)
            installation.stage(entrypoint)
            installation.stage(backup)
            if current == original_hash \
                    and (backup_bytes is None or digest(backup_bytes) != original_hash):
                os.replace(entrypoint, backup)
            installation.write(entrypoint, stub, 0o755)
            installation.write(record, json.dumps(next_record, indent=2).encode() + b"\n")
            installation.finish()
        except SystemExit:
            installation.rollback()
            raise
        except PermissionError:
            installation.rollback()
            raise SystemExit("Installation is read-only. After building as your normal user, run: sudo python3 devin/install.py --no-build")
        except OSError as error:
            installation.rollback()
            raise SystemExit(f"Installation failed: {error}")
        except Exception:
            installation.rollback()
            raise
        print(f"Installed Autonom launcher in {payload}.")
        print("Quit Desktop once, then run devin-desktop. Arguments and terminal output are unchanged from node dist/launcher.js.")
        print("Rollback: python3 devin/install.py --uninstall (use the same --app path and permissions).")


if __name__ == "__main__":
    main()
