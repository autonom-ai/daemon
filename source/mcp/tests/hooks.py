from support import DaemonTestCase


class HookTests(DaemonTestCase):
    def test_unmanaged_hooks_allow_ordinary_tools_and_deny_coordination(self):
        self.assertEqual(self.hook("PreToolUse", managed=False), {})
        result = self.hook("PreToolUse", tool="mcp__autonom-coord__set_profile", managed=False)
        self.assertEqual(result["decision"], "block")

    def test_managed_hook_authenticates_with_the_real_session_token_file(self):
        policy = self.workspace / ".devin/policy.yml"
        policy.parent.mkdir()
        policy.write_text("rules:\n  - action: allow\n")
        result = self.hook("PreToolUse")
        self.assertNotEqual(result.get("decision"), "block", result)
        policy.write_text('rules:\n  - action: deny\n    reason: "denied by test policy"\n')
        result = self.hook("PreToolUse", tool="exec", input={"command": "true"})
        self.assertEqual(result["decision"], "block")
        self.assertIn("denied by test policy", result["reason"])

    def test_permission_hook_defers_to_acp_without_polling(self):
        self.assertEqual(self.hook("PermissionRequest"), {})

    def test_managed_hook_transport_failure_blocks_the_tool(self):
        self.stop_daemon()
        self.assertEqual(self.hook("PreToolUse")["decision"], "block")
