import json

import coord
import daemon
import server
from support import DaemonTestCase, environment


class CoordinationTests(DaemonTestCase):
    def tool(self, name, arguments=None):
        result = coord.call_tool(name, arguments or {})
        self.assertFalse(result["isError"], result)
        self.assertNotIn(self.token, json.dumps(result))
        self.assertEqual(daemon.SESSION_CONTEXT.get(), "")
        return json.loads(result["content"][0]["text"])

    def test_unmanaged_processes_advertise_no_tools(self):
        with environment({"AUTONOM_MCP_TOKEN": ""}):
            result = server.handle({"id": 1, "method": "tools/list"})
            self.assertEqual(result["result"]["tools"], [])
            self.assertTrue(coord.call_tool("get_profiles", {})["isError"])

    def test_profile_identity_comes_from_the_capability(self):
        self.tool("set_profile", {"name": "marlow", "session_id": "spoofed"})
        profile = self.tool("get_profile_status")
        self.assertEqual(profile["session"]["id"], "managed")
        self.assertEqual(profile["name"], "marlow")
        self.assertEqual(daemon.session(), "managed")
        with self.assertRaises(daemon.ToolError):
            daemon.call("POST", "/api/profiles/marlow/session", {"id": "another-session"})
        self.assertEqual(self.tool("get_profile_status")["session"]["id"], "managed")

    def test_room_messages_and_membership_use_real_daemon_state(self):
        self.tool("set_profile", {"name": "marlow"})
        self.tool("create_room", {"name": "work"})
        self.tool("post_message", {"room": "work", "text": "hello"})
        messages = self.tool("read_messages", {"source": "room", "room": "work"})
        self.assertIn("hello", json.dumps(messages))
        self.assertIn("work", json.dumps(self.tool("list_rooms")))
        self.tool("set_room_involved", {"name": "work", "involved": ["marlow"]})
        self.tool("delete_room", {"name": "work"})
        self.assertNotIn('"name": "work"', json.dumps(self.tool("list_rooms")))

    def test_schedules_round_trip_and_cancel_without_running_a_model(self):
        self.tool("set_profile", {"name": "marlow"})
        schedule = self.tool("schedule", {"type": "clock", "every": 3600})
        schedules = self.tool("list_schedules")
        self.assertIn(schedule["id"], json.dumps(schedules))
        self.tool("cancel_schedule", {"id": schedule["id"]})
        self.assertEqual(self.tool("list_schedules"), [])

    def test_invalid_arguments_return_tool_errors_and_leave_context_clean(self):
        self.assertTrue(coord.call_tool("get_profiles", [])["isError"])
        self.assertTrue(coord.call_tool("post_message", {})["isError"])
        self.assertTrue(coord.call_tool("read_messages", {"source": "unknown"})["isError"])
        self.assertEqual(daemon.SESSION_CONTEXT.get(), "")
        self.tool("get_profiles")
