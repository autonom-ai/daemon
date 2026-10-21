#!/usr/bin/env python3
"""Automated style and architectural boundary checker for Autonom."""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
SOURCE = ROOT / "source"

UPPER_ENUM_RE = re.compile(r"^\s*enum\s+(?:[A-Za-z0-9_]+\s+)?([A-Z][A-Z0-9_]{2,})\s*=")
WHILE_TRUE_RE = re.compile(r"\b(?:while\s*\(\s*true\s*\)|for\s*\(\s*;\s*;\s*\))")
SCOPE_SPACE_RE = re.compile(r"\bscope\s+\((?:exit|failure|success)\)")
LOCAL_IMPORT_RE = re.compile(r"^\s{4,}import\s+[a-zA-Z0-9_.]+\s*[;:]")
INTEROP_FORBIDDEN_RE = re.compile(r"^\s*import\s+daemon\.(?:agent|coord|events|acp)\b")


def check_d_file(path: pathlib.Path) -> list[str]:
    errors = []
    rel = path.relative_to(ROOT)
    lines = path.read_text(encoding="utf-8").splitlines()

    if len(lines) > 400:
        errors.append(f"{rel}: {len(lines)} lines exceeds the 400-line ceiling")

    is_interop = "source/daemon/interop/" in str(rel)
    for idx, line in enumerate(lines, start=1):
        if line.endswith(" ") or line.endswith("\t"):
            errors.append(f"{rel}:{idx}: trailing whitespace")

        match = UPPER_ENUM_RE.match(line)
        if match:
            errors.append(f"{rel}:{idx}: UPPER_SNAKE_CASE constant '{match.group(1)}' (use camelCase)")

        if WHILE_TRUE_RE.search(line):
            errors.append(f"{rel}:{idx}: unbounded sentinel loop (while(true) / for(;;))")

        if SCOPE_SPACE_RE.search(line):
            errors.append(f"{rel}:{idx}: space after 'scope' in scope guard (use scope(exit))")

        if LOCAL_IMPORT_RE.match(line):
            errors.append(f"{rel}:{idx}: local import inside scope (keep imports at module scope)")

        if is_interop and INTEROP_FORBIDDEN_RE.match(line):
            errors.append(f"{rel}:{idx}: forbidden domain import inside daemon.interop: {line.strip()}")

    return errors


def main() -> int:
    targets = [pathlib.Path(arg).resolve() for arg in sys.argv[1:]] if len(sys.argv) > 1 else sorted(SOURCE.rglob("*.d"))
    all_errors = []
    for target in targets:
        if target.is_dir():
            for d_file in sorted(target.rglob("*.d")):
                all_errors.extend(check_d_file(d_file))
        elif target.suffix == ".d" and target.exists():
            all_errors.extend(check_d_file(target))

    if all_errors:
        for err in all_errors:
            print(err, file=sys.stderr)
        print(f"\nFound {len(all_errors)} style/boundary issue(s).", file=sys.stderr)
        return 1

    print("All checked D files pass style and boundary checks.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
