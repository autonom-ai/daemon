import json
import os
import subprocess
import unittest

from support import COMMAND


class ProtocolTests(unittest.TestCase):
    def test_stdio_initialization_and_parse_failures_preserve_request_ids(self):
        requests = [
            json.dumps({"id": "init", "method": "initialize", "params": {"protocolVersion": "unknown"}}),
            json.dumps({"id": 2, "method": "tools/list"}),
            json.dumps({"method": "notifications/initialized"}),
            "invalid JSON",
        ]
        result = subprocess.run([str(COMMAND), "mcp"], input="\n".join(requests) + "\n",
                                text=True, capture_output=True, timeout=10,
                                env=dict(os.environ, AUTONOM_MCP_TOKEN=""))
        self.assertEqual(result.returncode, 0, result.stderr)
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(replies), 3)
        self.assertEqual(replies[0]["id"], "init")
        self.assertEqual(replies[0]["result"]["protocolVersion"], "2025-03-26")
        self.assertEqual(replies[1]["id"], 2)
        self.assertEqual(replies[1]["result"]["tools"], [])
        self.assertEqual(replies[2]["error"]["code"], -32700)
