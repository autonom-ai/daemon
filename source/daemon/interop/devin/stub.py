#!/usr/bin/env python3
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RELAY = os.path.normpath(os.path.join(ROOT, "..", "..", "..", "..", "bin", "autonom-acp"))
if not os.path.exists(RELAY):
    RELAY = "autonom-acp"


def main():
    arguments = [os.path.abspath(RELAY) if os.path.exists(RELAY) else RELAY]
    arguments += ["--devin", os.environ.get("AUTONOM_DEVIN", "devin")]
    if os.environ.get("AUTONOM_CONFIG"):
        arguments += ["--config", os.environ["AUTONOM_CONFIG"]]
    arguments += sys.argv[1:]
    os.execv(arguments[0], arguments)


if __name__ == "__main__":
    main()
