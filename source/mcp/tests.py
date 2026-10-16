import contextlib
import io
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "daemon", "interop", "devin"))

import hook
import server


class CoordinationTests(unittest.TestCase):
    def setUp(self):
        server.RESOLVED_SESSION = None

    @contextlib.contextmanager
    def mock_daemon(self):
        captured = {"requests": []}

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                captured["requests"].append({
                    "path": self.path,
                    "mcp": self.headers.get("x-autonom-mcp"),
                    "run": self.headers.get("x-autonom-run"),
                    "session": self.headers.get("x-autonom-session"),
                })
                body = b'{"id": "managed-session"}' if self.path == "/api/mcp/session" else b"[]"
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *arguments):
                pass

        daemon = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=daemon.serve_forever, daemon=True)
        thread.start()
        try:
            yield daemon, captured
        finally:
            daemon.shutdown()
            daemon.server_close()
            thread.join()

    @contextlib.contextmanager
    def token_file(self, session="managed", token="file-token"):
        with tempfile.TemporaryDirectory() as directory:
            os.makedirs(os.path.join(directory, "mcp"))
            with open(os.path.join(directory, "mcp", session + ".token"), "w") as handle:
                handle.write(" " + token + "\n")
            yield directory

    def run_hook(self, data):
        stdin = io.TextIOWrapper(io.BytesIO(json.dumps(data).encode()))
        with patch("sys.stdin", stdin), contextlib.redirect_stdout(io.StringIO()) as output:
            hook.run()
        return json.loads(output.getvalue())

    def test_unmanaged_mcp_advertises_no_tools(self):
        with patch.dict(os.environ, {}, clear=True):
            result = server.handle({"id": 1, "method": "tools/list"})
            self.assertEqual(result["result"]["tools"], [])
            result = server.call_tool("get_profiles", {"session_id": "desktop-session"})
            self.assertTrue(result["isError"])
            self.assertIn("Only sessions started", result["content"][0]["text"])

    def test_managed_tools_send_session_token_and_resolved_session(self):
        with self.mock_daemon() as (daemon, captured):
            with patch.dict(os.environ, {"AUTONOM_MCP_TOKEN": "private-capability",
                                       "AUTONOM_PORT": str(daemon.server_port)}, clear=True):
                result = server.call_tool("get_profiles", {"session_id": "spoofed"})
                self.assertFalse(result["isError"])
                self.assertNotIn("private-capability", json.dumps(result))

        resolution = next(r for r in captured["requests"] if r["path"] == "/api/mcp/session")
        self.assertEqual(resolution["mcp"], "private-capability")
        coord = next(r for r in captured["requests"] if r["path"] == "/api/profiles")
        self.assertEqual(coord["mcp"], "private-capability")
        self.assertEqual(coord["session"], "managed-session")
        self.assertIsNone(coord["run"])

    def test_unmanaged_hooks_do_not_screen_ordinary_tools(self):
        data = {"hook_event_name": "PreToolUse", "session_id": "desktop", "tool_name": "read"}
        with patch.dict(os.environ, {}, clear=True), patch.object(hook, "call") as request:
            self.assertEqual(self.run_hook(data), {})
            request.assert_not_called()

    def test_unmanaged_hooks_block_autonom_tools(self):
        for tool in ("mcp__autonom-coord__set_profile", "mcp__autonom-orchestrate__team_start"):
            with self.subTest(tool=tool), patch.dict(os.environ, {}, clear=True):
                data = {"hook_event_name": "PreToolUse", "session_id": "desktop", "tool_name": tool}
                self.assertEqual(self.run_hook(data)["decision"], "block")

    def test_managed_hook_forwards_with_session_token_file(self):
        data = {"hook_event_name": "PreToolUse", "session_id": "managed", "tool_name": "exec"}
        with self.token_file() as directory:
            with patch.dict(os.environ, {"AUTONOM_DATA_DIR": directory}, clear=True), \
                 patch.object(hook, "call", return_value={}) as request:
                self.assertEqual(self.run_hook(data), {})
                request.assert_called_once_with(
                    "POST", "/api/hooks/pre-tool-use", data)

    def test_hook_call_sends_session_credentials(self):
        captured = []

        class Reply:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self, limit=-1):
                return b"{}"

        def open(request, **kwargs):
            captured.append(request)
            return Reply()

        with self.token_file() as directory:
            with patch.dict(os.environ, {"AUTONOM_DATA_DIR": directory}, clear=True), \
                 patch.object(hook.HTTP, "open", side_effect=open):
                hook.call("POST", "/api/hooks/pre-tool-use", {"session_id": "managed"})
        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}, clear=True), \
             patch.object(hook.HTTP, "open", side_effect=open):
            hook.call("POST", "/api/hooks/pre-tool-use", {"session_id": "managed"})

        mcp_request, run_request = captured
        self.assertEqual(mcp_request.get_header("X-autonom-mcp"), "file-token")
        self.assertEqual(mcp_request.get_header("X-autonom-session"), "managed")
        self.assertFalse(mcp_request.get_header("X-autonom-run"))
        self.assertEqual(run_request.get_header("X-autonom-run"), "private")
        self.assertIsNone(run_request.get_header("X-autonom-mcp"))
        self.assertNotIn(b"file-token", mcp_request.data or b"")

    def test_managed_hook_failure_blocks_instead_of_allowing_a_tool(self):
        data = {"hook_event_name": "PreToolUse", "session_id": "managed", "tool_name": "exec"}
        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}), \
             patch.object(hook, "call", side_effect=server.ToolError("unreachable")):
            self.assertEqual(self.run_hook(data)["decision"], "block")

        with self.token_file() as directory:
            with patch.dict(os.environ, {"AUTONOM_DATA_DIR": directory}, clear=True), \
                 patch.object(hook, "call", side_effect=server.ToolError("unreachable")):
                self.assertEqual(self.run_hook(data)["decision"], "block")

    def test_permission_approval_waits_outside_the_request_worker(self):
        responses = [{"permission": "permission-id"}, {"decision": ""}, {"decision": "approve"}]
        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}), \
             patch.object(hook, "call", side_effect=responses), patch.object(hook.time, "sleep"):
            result = hook.forward({"session_id": "managed"}, "PermissionRequest")
            self.assertEqual(result["decision"], "approve")
            self.assertEqual(server.SESSION_CONTEXT.get(), "")

    def test_argument_validation_returns_mcp_errors(self):
        self.assertTrue(server.call_tool("get_profiles", [])["isError"])
        with patch.dict(os.environ, {}, clear=True):
            self.assertTrue(server.call_tool("get_profiles", {})["isError"])

        with self.mock_daemon() as (daemon, captured):
            with patch.dict(os.environ, {"AUTONOM_MCP_TOKEN": "private-capability",
                                       "AUTONOM_PORT": str(daemon.server_port)}, clear=True):
                result = server.call_tool("post_message", {})
                self.assertTrue(result["isError"])
                self.assertIn("text", result["content"][0]["text"])
                self.assertFalse(server.call_tool("get_profiles", {})["isError"])

            self.assertEqual(
                [r["path"] for r in captured["requests"]].count("/api/mcp/session"), 1)


if __name__ == "__main__":
    unittest.main()
