import contextlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

import daemon

REPOSITORY = Path(__file__).resolve().parents[3]
HOOK = REPOSITORY / "source/daemon/interop/devin/hook.py"
SERVER = REPOSITORY / "source/mcp/server.py"
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


@contextlib.contextmanager
def environment(values):
    previous = dict(os.environ)
    try:
        os.environ.update(values)
        yield
    finally:
        os.environ.clear()
        os.environ.update(previous)


class DaemonTestCase(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="autonom-mcp-")
        self.addCleanup(self.directory.cleanup)
        self.workspace = Path(self.directory.name)
        self.data = self.workspace / "data"
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.port = listener.getsockname()[1]
        config = self.workspace / "config.yml"
        config.write_text("dataDir: data\ndevinCommand: /bin/false\nsessionLockDir: locks\nrouter:\n  type: openrouter\n  key: unused\n"
                          "  url: https://openrouter.ai\n  name: OpenRouter\n")
        self.env = dict(os.environ, AUTONOM_CONFIG=str(config), AUTONOM_PORT=str(self.port),
                        AUTONOM_DATA_DIR=str(self.data), AUTONOM_RUN_TOKEN="", AUTONOM_CLIENT_TOKEN="")
        self.log = tempfile.TemporaryFile()
        self.addCleanup(self.log.close)
        self.process = subprocess.Popen([str(REPOSITORY / "bin/autonom-daemon")], env=self.env,
                                        stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.log)
        self.addCleanup(self.stop_daemon)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                self.request("GET", "/api/health", operator=False)
                break
            except OSError:
                if self.process.poll() is not None:
                    self.log.seek(0)
                    self.fail(self.log.read().decode())
                time.sleep(0.01)
        else:
            self.log.seek(0)
            self.fail("Production daemon did not become ready: " + self.log.read().decode()[-4000:])
        self.capability = (self.data / "client.token").read_text().strip()
        self.token = secrets.token_hex(32)
        self.request("POST", "/api/acp/admit", {
            "connection": "00000000-0000-0000-0000-000000000001", "session": "managed",
            "directory": str(self.workspace), "token": self.token,
        })
        self.env["AUTONOM_MCP_TOKEN"] = self.token
        self.environment = environment(self.env)
        self.environment.__enter__()
        self.addCleanup(self.environment.__exit__, None, None, None)
        daemon.RESOLVED_SESSION = None

    def stop_daemon(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)

    def request(self, method, path, body=None, operator=True):
        headers = {"content-type": "application/json"}
        if operator:
            headers["x-autonom-client"] = self.capability
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}", method=method, headers=headers,
            data=json.dumps(body).encode() if body is not None else None)
        with HTTP.open(request, timeout=2) as response:
            return json.loads(response.read())

    def hook(self, event, tool="read", input=None, managed=True, **overrides):
        env = dict(self.env, **overrides)
        if not managed:
            env.pop("AUTONOM_DATA_DIR", None)
            env.pop("AUTONOM_MCP_TOKEN", None)
        result = subprocess.run([sys.executable, str(HOOK), "--event", event],
                                input=json.dumps({"hook_event_name": event, "session_id": "managed",
                                                  "tool_name": tool, "tool_input": input or {},
                                                  "cwd": str(self.workspace)}),
                                text=True, capture_output=True, timeout=15, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)
