#!/usr/bin/env python3
"""acp-shim: a transparent middleman between an ACP client and `devin acp`.

Devin Desktop spawns this process like any other registry agent; the shim spawns
the real Devin CLI ACP server and relays bytes verbatim in both directions, so
the session behaves exactly like Devin Local while we observe the stream.

Environment:
    ACP_SHIM_DEVIN  devin binary to exec (default: devin on PATH)
    ACP_SHIM_LOG    file path to tap every JSON-RPC frame, one JSON line each:
                    {"dir":"<"|">","ts":<epoch>,"id":..,"method":..}

Extra command-line arguments are forwarded to `devin acp`.
"""

import ctypes
import json
import os
import signal
import subprocess
import sys
import threading
import time

CHUNK = 65536


def command(argv):
    return [os.environ.get("ACP_SHIM_DEVIN", "devin"), "acp", *argv]


def death_signal():
    if sys.platform != "linux":
        return None

    libc = ctypes.CDLL(None)

    def assign():
        libc.prctl(1, signal.SIGKILL)

    return assign


def write_all(descriptor, data):
    while data:
        written = os.write(descriptor, data)
        data = data[written:]


class Tap:
    def __init__(self, path):
        self.lock = threading.Lock()
        self.stream = open(path, "a", encoding="utf-8", buffering=1)

    def frame(self, direction, data):
        try:
            message = json.loads(data)
        except ValueError:
            return

        record = {"dir": direction, "ts": time.time()}
        if "id" in message:
            record["id"] = message["id"]
        if "method" in message:
            record["method"] = message["method"]
        params = message.get("params")
        if isinstance(params, dict):
            if isinstance(params.get("sessionId"), str):
                record["session"] = params["sessionId"]
            if isinstance(params.get("session_id"), str):
                record["session"] = params["session_id"]
        result = message.get("result")
        if isinstance(result, dict) and isinstance(result.get("sessionId"), str):
            record["session"] = result["sessionId"]

        with self.lock:
            self.stream.write(json.dumps(record, separators=(",", ":")) + "\n")


def pump(read_fd, write_fd, direction, tap):
    buffered = b""
    try:
        while True:
            chunk = os.read(read_fd, CHUNK)
            if not chunk:
                break
            write_all(write_fd, chunk)
            if tap is not None:
                buffered += chunk
                while b"\n" in buffered:
                    frame, buffered = buffered.split(b"\n", 1)
                    if frame.strip():
                        tap.frame(direction, frame)
    except OSError:
        pass
    if buffered.strip() and tap is not None:
        tap.frame(direction, buffered)


def main():
    process = subprocess.Popen(
        command(sys.argv[1:]),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        bufsize=0,
        preexec_fn=death_signal(),
    )

    tap = None
    path = os.environ.get("ACP_SHIM_LOG")
    if path:
        try:
            tap = Tap(path)
        except OSError:
            pass

    inbound = threading.Thread(
        target=pump, args=(sys.stdin.fileno(), process.stdin.fileno(), ">", tap), daemon=True
    )
    outbound = threading.Thread(
        target=pump, args=(process.stdout.fileno(), sys.stdout.fileno(), "<", tap), daemon=True
    )
    inbound.start()
    outbound.start()

    def close_input():
        inbound.join()
        try:
            process.stdin.close()
        except OSError:
            pass

    threading.Thread(target=close_input, daemon=True).start()
    os._exit(process.wait())


if __name__ == "__main__":
    main()
