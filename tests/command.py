"""Smoke tests for the Autonom command surface."""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
COMMAND = REPOSITORY / "bin/autonom"
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


class CommandTests(unittest.TestCase):
    def setUp(self):
        if not COMMAND.is_file():
            self.skipTest("Build the command with dub build --compiler=ldc2 --config=daemon first.")

        self.root = Path(tempfile.mkdtemp(prefix="autonom-command-"))
        self.addCleanup(shutil.rmtree, self.root, True)

    def run_command(self, *arguments, **options):
        return subprocess.run([str(COMMAND), *arguments], capture_output=True, text=True,
                              timeout=60, **options)

    def test_help_and_version_describe_the_command(self):
        help_result = self.run_command("--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("Usage: autonom <command> [options]", help_result.stdout)
        for command in ["daemon", "acp", "mcp", "hook"]:
            self.assertIn(command, help_result.stdout)

        version_result = self.run_command("--version")
        self.assertEqual(version_result.returncode, 0, version_result.stderr)
        self.assertIn("Autonom", version_result.stdout)

        unknown = self.run_command("nonsense")
        self.assertEqual(unknown.returncode, 1)
        self.assertIn("unknown command", unknown.stderr)

    def test_the_mcp_proxy_answers_over_stdio(self):
        requests = [
            json.dumps({"id": "init", "method": "initialize", "params": {"protocolVersion": "2025-03-26"}}),
            json.dumps({"id": 2, "method": "tools/list"}),
        ]
        result = subprocess.run([str(COMMAND), "mcp"], input="\n".join(requests) + "\n",
                                capture_output=True, text=True, timeout=30,
                                env=dict(os.environ, AUTONOM_MCP_TOKEN=""))
        self.assertEqual(result.returncode, 0, result.stderr)
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(replies), 2)
        self.assertEqual(replies[0]["result"]["serverInfo"]["name"], "autonom-coord")
        self.assertEqual(replies[1]["result"]["tools"], [])

    def test_the_hook_fails_closed_without_the_daemon(self):
        payload = json.dumps({"hook_event_name": "PreToolUse", "session_id": "none",
                              "tool_name": "exec", "tool_input": {"command": "true"}})
        environment = dict(os.environ, AUTONOM_PORT=str(free_port()), AUTONOM_RUN_TOKEN="run-token")
        result = subprocess.run([str(COMMAND), "hook", "--event", "PreToolUse"], input=payload,
                                capture_output=True, text=True, timeout=30, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["decision"], "block")

        result = subprocess.run([str(COMMAND), "hook", "--event", "Stop"], input=payload,
                                capture_output=True, text=True, timeout=30, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {})

    def test_daemon_ensure_starts_and_reports_the_daemon(self):
        port = free_port()
        config = self.root / "config.yml"
        config.write_text(f"dataDir: {self.root / 'data'}\ndevinCommand: devin\nrouter:\n"
                          '  type: openrouter\n  key: "command-test-key"\n'
                          "  url: https://openrouter.ai\n  name: OpenRouter\n")
        environment = dict(os.environ, AUTONOM_CONFIG=str(config), AUTONOM_PORT=str(port),
                           XDG_CONFIG_HOME=str(self.root / "xdg-config"),
                           XDG_CACHE_HOME=str(self.root / "xdg-cache"))
        result = subprocess.run([str(COMMAND), "daemon", "--ensure"], capture_output=True, text=True,
                                timeout=60, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        health = json.loads(result.stdout)
        self.assertEqual(health["status"], "ok")
        self.assertEqual(health["configFile"], str(config))

        capability = (self.root / "data" / "client.token").read_text().strip()
        request = urllib.request.Request(f"http://127.0.0.1:{port}/api/stop", method="POST",
                                         data=b"{}", headers={"x-autonom-client": capability,
                                                             "content-type": "application/json"})
        with HTTP.open(request, timeout=10) as response:
            self.assertEqual(json.loads(response.read())["status"], "stopping")

        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            try:
                with HTTP.open(f"http://127.0.0.1:{port}/api/health", timeout=1) as response:
                    response.read()

                time.sleep(0.1)
            except OSError as failure:
                close = getattr(failure, "close", None)
                if close is not None:
                    close()

                break


if __name__ == "__main__":
    unittest.main()
