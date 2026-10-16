import contextlib
import io
import json
import os
import tempfile
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import patch

import hook
import orchestrate
import server


class CoordinationTests(unittest.TestCase):
    def test_unmanaged_mcp_advertises_no_tools(self):
        with patch.dict(os.environ, {}, clear=True):
            result = server.handle({"id": 1, "method": "tools/list"})
            self.assertEqual(result["result"]["tools"], [])
            result = server.call_tool("get_profiles", {"session_id": "desktop-session"})
            self.assertTrue(result["isError"])
            self.assertIn("Only sessions started", result["content"][0]["text"])

    def test_unmanaged_hooks_do_not_screen_ordinary_tools(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(hook, "call") as request:
            result = hook.forward({"hook_event_name": "PreToolUse", "session_id": "desktop", "tool_name": "read"})
            self.assertEqual(result, {})
            request.assert_not_called()

    def test_unmanaged_hooks_block_autonom_tools(self):
        with patch.dict(os.environ, {}, clear=True):
            result = hook.forward({"hook_event_name": "PreToolUse", "session_id": "desktop",
                                   "tool_name": "mcp__autonom-coord__set_profile"})
            self.assertEqual(result["decision"], "block")

    def test_managed_tools_forward_private_capability_and_injected_session(self):
        captured = {}

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                captured["token"] = self.headers.get("x-autonom-run")
                captured["session"] = self.headers.get("x-autonom-session")
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.end_headers()
                self.wfile.write(b"[]")

            def log_message(self, *arguments):
                pass

        daemon = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=daemon.serve_forever, daemon=True)
        thread.start()
        try:
            with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private-capability",
                                       "AUTONOM_PORT": str(daemon.server_port)}):
                result = server.call_tool("get_profiles", {"session_id": "managed-session"})
                self.assertFalse(result["isError"])
                self.assertEqual(captured["token"], "private-capability")
                self.assertEqual(captured["session"], "managed-session")
                self.assertNotIn("private-capability", json.dumps(result))
        finally:
            daemon.shutdown()
            daemon.server_close()
            thread.join()

    def test_managed_hook_failure_blocks_instead_of_allowing_a_tool(self):
        data = {"hook_event_name": "PreToolUse", "session_id": "managed", "tool_name": "exec"}
        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}), \
             patch.object(hook, "call", side_effect=server.ToolError("unreachable")), \
             patch("sys.stdin", io.StringIO(json.dumps(data))), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            hook.run()
            self.assertEqual(json.loads(output.getvalue())["decision"], "block")

    def test_permission_approval_waits_outside_the_request_worker(self):
        responses = [{"permission": "permission-id"}, {"decision": ""}, {"decision": "approve"}]
        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}), \
             patch.object(hook, "call", side_effect=responses), patch.object(hook.time, "sleep"):
            result = hook.forward({"hook_event_name": "PermissionRequest", "session_id": "managed"})
            self.assertEqual(result["decision"], "approve")
            self.assertEqual(server.SESSION_CONTEXT.get(), "")

    def test_argument_validation_returns_mcp_errors(self):
        self.assertTrue(server.call_tool("get_profiles", [])["isError"])
        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}):
            self.assertTrue(server.call_tool("get_profiles", {})["isError"])


class OrchestrationTests(unittest.TestCase):
    def test_unmanaged_sessions_advertise_no_tools(self):
        with patch.dict(os.environ, {}, clear=True):
            result = orchestrate.handle({"id": 1, "method": "tools/list"})
            self.assertEqual(result["result"]["tools"], [])
            result = orchestrate.call_tool("team_status", {})
            self.assertTrue(result["isError"])
            self.assertIn("Only sessions started", result["content"][0]["text"])

    def test_data_directory_prefers_the_override(self):
        with patch.dict(os.environ, {"AUTONOM_DATA_DIR": "/tmp/autonom-data"}, clear=True):
            self.assertEqual(orchestrate.data_directory(), "/tmp/autonom-data")

    def test_data_directory_reads_the_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "config.yml")
            with open(path, "w", encoding="utf-8") as config:
                config.write("dataDir: relative-data  # comment\n")

            with patch.dict(os.environ, {"AUTONOM_CONFIG": path}, clear=True):
                self.assertEqual(orchestrate.data_directory(), os.path.join(directory, "relative-data"))

    def test_client_token_reads_the_private_capability(self):
        with tempfile.TemporaryDirectory() as directory:
            with open(os.path.join(directory, "client.token"), "w", encoding="utf-8") as token:
                token.write("a" * 64)

            with patch.dict(os.environ, {"AUTONOM_DATA_DIR": directory}, clear=True):
                self.assertEqual(orchestrate.client_token(), "a" * 64)

    def test_invalid_client_token_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            with open(os.path.join(directory, "client.token"), "w", encoding="utf-8") as token:
                token.write("short")

            with patch.dict(os.environ, {"AUTONOM_DATA_DIR": directory}, clear=True):
                with self.assertRaises(orchestrate.ToolError):
                    orchestrate.client_token()

    def test_team_start_creates_the_profile_and_launches_a_session(self):
        calls = []

        def fake(method, path, body=None, query=None):
            calls.append((method, path, body))
            if method == "GET" and path == "/api/profiles":
                return []
            if method == "GET" and path == "/api/client/state":
                return {"sessions": [{"id": "orchestrator", "directory": "/repo", "model": "swe-2-medium"}]}
            return {"accepted": True}

        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}), \
             patch.object(orchestrate, "call", side_effect=fake):
            result = orchestrate.dispatch("team_start", {
                "session_id": "orchestrator",
                "profile": "builder",
                "prompt": "Implement the feature",
            })

        self.assertEqual(result, {"accepted": True})
        self.assertIn(("POST", "/api/profiles", {"name": "builder"}), calls)
        launch = calls[-1]
        self.assertEqual(launch[0], "POST")
        self.assertEqual(launch[1], "/api/sessions")
        self.assertEqual(launch[2]["directory"], "/repo")
        self.assertEqual(launch[2]["profile"], "builder")
        self.assertEqual(launch[2]["mode"], "bypass")
        self.assertEqual(launch[2]["model"], "swe-2-medium")

    def test_team_start_prefers_a_worktree_directory(self):
        calls = []

        def fake(method, path, body=None, query=None):
            calls.append((method, path, body))
            if method == "GET" and path == "/api/profiles":
                return [{"name": "builder", "session": None}]
            if method == "GET" and path == "/api/worktrees":
                return [{"name": "builder", "path": "/repo/.autonom-worktrees/builder", "status": "ready"}]
            if method == "GET" and path == "/api/client/state":
                return {"sessions": [{"id": "orchestrator", "directory": "/repo", "model": "swe-2-medium"}]}
            return {"accepted": True}

        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}), \
             patch.object(orchestrate, "call", side_effect=fake):
            orchestrate.dispatch("team_start", {
                "session_id": "orchestrator",
                "profile": "builder",
                "prompt": "Implement the feature",
                "worktree": "builder",
            })

        self.assertEqual(calls[-1][2]["directory"], "/repo/.autonom-worktrees/builder")

    def test_team_start_rejects_a_missing_worktree(self):
        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}), \
             patch.object(orchestrate, "call", return_value=[]):
            with self.assertRaises(orchestrate.ToolError):
                orchestrate.dispatch("team_start", {
                    "session_id": "orchestrator",
                    "profile": "builder",
                    "prompt": "Implement the feature",
                    "worktree": "builder",
                })

    def test_team_wait_polls_until_the_execution_finishes(self):
        statuses = [{"status": "running"}, {"status": "running"}, {"status": "succeeded"}]

        def fake(method, path, body=None, query=None):
            return statuses.pop(0)

        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}), \
             patch.object(orchestrate, "call", side_effect=fake), \
             patch.object(orchestrate.time, "sleep"):
            result = orchestrate.dispatch("team_wait", {
                "session_id": "orchestrator",
                "execution": "execution-1",
                "timeout": 5,
            })

        self.assertEqual(result["status"], "succeeded")

    def test_team_remove_refuses_an_unknown_profile(self):
        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}), \
             patch.object(orchestrate, "call", return_value=[]):
            with self.assertRaises(orchestrate.ToolError):
                orchestrate.dispatch("team_remove", {"session_id": "orchestrator", "profile": "builder"})

    def test_team_message_posts_as_the_human_operator(self):
        calls = []

        def fake(method, path, body=None, query=None):
            calls.append((method, path, body))
            return {"posted": True}

        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}), \
             patch.object(orchestrate, "call", side_effect=fake):
            orchestrate.dispatch("team_message", {
                "session_id": "orchestrator",
                "room": "merge-builder-tester",
                "text": "Resolve the conflict",
                "ping": ["builder", "tester"],
            })

        self.assertEqual(calls[-1][0], "POST")
        self.assertEqual(calls[-1][1], "/api/client/rooms/merge-builder-tester/messages")
        self.assertEqual(calls[-1][2], {"text": "Resolve the conflict", "ping": ["builder", "tester"]})

    def test_hook_guards_the_orchestrate_tools(self):
        with patch.dict(os.environ, {}, clear=True):
            result = hook.forward({"hook_event_name": "PreToolUse", "session_id": "desktop",
                                   "tool_name": "mcp__autonom-orchestrate__team_start"})
            self.assertEqual(result["decision"], "block")

    def test_team_merge_posts_the_source_worktree(self):
        calls = []

        def fake(method, path, body=None, query=None):
            calls.append((method, path, body))
            return {"status": "merged"}

        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}), \
             patch.object(orchestrate, "call", side_effect=fake):
            result = orchestrate.dispatch("team_merge", {
                "session_id": "orchestrator",
                "target": "builder",
                "source": "tester",
            })

        self.assertEqual(result, {"status": "merged"})
        self.assertEqual(calls[-1], ("POST", "/api/worktrees/builder/merge", {"source": "tester"}))

    def test_team_worktree_remove_passes_force_as_a_query(self):
        calls = []

        def fake(method, path, body=None, query=None):
            calls.append((method, path, body, query))
            return {"name": "tester"}

        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}), \
             patch.object(orchestrate, "call", side_effect=fake):
            orchestrate.dispatch("team_worktree_remove", {
                "session_id": "orchestrator",
                "name": "tester",
                "force": True,
            })

        self.assertEqual(calls[-1], ("DELETE", "/api/worktrees/tester", None, {"force": "true"}))

    def test_team_wait_returns_immediately_for_a_finished_execution(self):
        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}), \
             patch.object(orchestrate, "call", return_value={"status": "failed", "error": "boom"}), \
             patch.object(orchestrate.time, "sleep") as sleep:
            result = orchestrate.dispatch("team_wait", {
                "session_id": "orchestrator",
                "execution": "execution-1",
                "timeout": 30,
            })

        self.assertEqual(result["status"], "failed")
        sleep.assert_not_called()

    def test_team_merge_surfaces_a_conflict(self):
        with patch.dict(os.environ, {"AUTONOM_RUN_TOKEN": "private"}), \
             patch.object(orchestrate, "call", return_value={
                 "status": "conflict",
                 "files": ["app.txt"],
                 "merge": {"room": "merge-builder-tester"},
             }):
            result = orchestrate.dispatch("team_merge", {
                "session_id": "orchestrator",
                "target": "builder",
                "source": "tester",
            })

        self.assertEqual(result["status"], "conflict")
        self.assertEqual(result["merge"]["room"], "merge-builder-tester")


if __name__ == "__main__":
    unittest.main()
