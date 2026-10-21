#!/usr/bin/env python3
"""Install the Autonom daemon command for the current user.

The command lives in the user data root and is exposed through the user's
local binary directory. Configuration, data, sessions, and logs are never
written or removed by this script.
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

COMMAND = "autonom"
BINARY = Path("bin") / COMMAND
RUNTIME = ("source/mcp", "templates")
EXCLUDED = (Path("source/mcp/tests.py"),)


def repository():
    """The checkout that holds the runtime files."""
    return Path(__file__).resolve().parent


def layout(prefix):
    """Return the data, binary, and configuration roots for the prefix."""
    if prefix:
        base = Path(prefix).resolve()
        return base / "share" / "autonom", base / "bin", base / "config" / "autonom"

    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return data / "autonom", Path.home() / ".local" / "bin", config / "autonom"


def runtime_files(source):
    """The runtime files the command needs, relative to the checkout."""
    ret = [BINARY]
    for directory in RUNTIME:
        ret.extend(sorted(path.relative_to(source) for path in (source / directory).glob("*")
                          if path.is_file() and path.relative_to(source) not in EXCLUDED
                          and "__pycache__" not in path.parts))

    return ret


def on_path(directory):
    """Whether the directory is already on the user's PATH."""
    return any(Path(entry) == directory for entry in os.environ.get("PATH", "").split(os.pathsep))


def refuse_symlinked_parents(path, root):
    """Refuse to write through a symlinked directory inside the installation root."""
    current = path
    while current != root and current != current.parent:
        if current.is_symlink():
            raise SystemExit(f"Refusing to write through a symlinked path: {current}")

        current = current.parent


def install(source, data, binaries, configs, build):
    if build:
        subprocess.run(["dub", "build", "--compiler=ldc2", "--config=daemon"], cwd=source, check=True)

    files = runtime_files(source)
    for name in files:
        if not (source / name).is_file():
            raise SystemExit(f"The Autonom runtime is incomplete: {name} is missing. "
                             "Build the command with dub build --compiler=ldc2 --config=daemon.")

    refuse_symlinked_parents(data / BINARY, data)
    refuse_symlinked_parents(binaries, binaries.parent)

    command = binaries / COMMAND
    if os.path.lexists(command) and not owned_command(command, data):
        raise SystemExit(f"Refusing to replace an unrelated command: {command}")

    for name in files:
        target = data / name
        if target.is_symlink():
            raise SystemExit(f"Refusing to write through a symlinked file: {target}")

        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target)
        if name == BINARY:
            os.chmod(target, 0o755)

    command.parent.mkdir(parents=True, exist_ok=True)
    if command.is_symlink():
        command.unlink()
    os.symlink(data / BINARY, command)

    config = configs / "config.yml"
    if not os.path.lexists(config):
        config.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / "templates" / "config.yml", config)
        os.chmod(config, 0o600)
        print(f"Created {config} from the packaged template.")
    else:
        print(f"Kept the existing {config}.")

    print(f"Installed the Autonom command in {data}.")
    print(f"{command} runs {data / BINARY}.")
    if not on_path(binaries):
        print(f"{binaries} is not on PATH. Add it to the shell profile to use the command everywhere:")
        print(f"    export PATH=\"{binaries}:$PATH\"")

    return 0


def owned_command(command, data):
    """Whether the command path already points at this installation."""
    return command.is_symlink() and command.resolve() == (data / BINARY).resolve()


def uninstall(data, binaries, configs):
    command = binaries / COMMAND
    removed = []
    if owned_command(command, data):
        command.unlink()
        removed.append(str(command))

    for name in runtime_files(repository()):
        target = data / name
        if target.is_file() and not target.is_symlink():
            target.unlink()
            removed.append(str(target))

    for directory in ("source/mcp", "source", "templates"):
        path = data / directory
        if path.is_dir() and not any(path.iterdir()):
            path.rmdir()

    for name in removed:
        print(f"Removed {name}.")
    if not removed:
        print("The Autonom command is not installed; nothing to remove.")
    print(f"Kept {configs}, the session data, and the logs.")

    return 0


def check(data, binaries, configs):
    command = binaries / COMMAND
    binary = data / BINARY
    print(f"Autonom command: {command}")
    if owned_command(command, data) and binary.is_file():
        print(f"Installed: {binary}.")
    elif os.path.lexists(command):
        print("The command path is not owned by this installation.")
    else:
        print("Not installed.")

    config = configs / "config.yml"
    print(f"Configuration: {config} ({'present' if config.exists() else 'missing'}).")
    if not on_path(binaries):
        print(f"{binaries} is not on PATH.")

    return 0


def main():
    parser = argparse.ArgumentParser(description="Install the Autonom daemon command for the current user.")
    parser.add_argument("--prefix", type=Path, help="install into this prefix instead of the user directories")
    parser.add_argument("--no-build", action="store_true", help="install the runtime that is already built")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--uninstall", action="store_true", help="remove the installed command and runtime")
    action.add_argument("--check", action="store_true", help="report the installation state")
    args = parser.parse_args()

    source = repository()
    data, binaries, configs = layout(args.prefix)
    if args.check:
        return check(data, binaries, configs)
    if args.uninstall:
        return uninstall(data, binaries, configs)

    return install(source, data, binaries, configs, not args.no_build)


if __name__ == "__main__":
    sys.exit(main())
