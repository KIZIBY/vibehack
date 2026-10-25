"""Unit tests for Hermes role tool guard (Spike T001 / R3).

Tests verify that:
1. Role 'code' cannot execute terminal / bash / shell commands.
2. Allowed inspection tools pass through.
3. Unknown or unauthenticated roles are denied by default (fail-closed).
4. Path traversal / write outside workspace is blocked.
"""
import unittest
from pathlib import Path
import sys

HERMES_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERMES_DIR / "plugins" / "ai-judge"))

try:
    import guard
except ImportError:
    guard = None


class RoleToolGuardTest(unittest.TestCase):
    def setUp(self):
        if guard is None:
            self.fail("guard module is not implemented yet (RED phase)")

    def test_extract_role_from_session_id(self):
        self.assertEqual(guard.extract_role("role:code:sub_123"), "code")
        self.assertEqual(guard.extract_role("code:sub_456"), "code")
        self.assertEqual(guard.extract_role("role:critic-uniqueness:run_1"), "critic-uniqueness")
        self.assertIsNone(guard.extract_role("invalid_session_without_role"))

    def test_code_role_blocks_terminal_and_execution_tools(self):
        blocked_tools = ["terminal", "bash", "execute_command", "sh", "run_shell", "process_spawn"]
        for tool in blocked_tools:
            with self.subTest(tool=tool):
                allowed, reason = guard.check_tool_call(tool, {}, session_id="role:code:sub_123")
                self.assertFalse(allowed, f"Tool {tool} must be blocked for role 'code'")
                self.assertIn("blocked", reason.lower())

    def test_code_role_allows_code_inspection_and_reporting_tools(self):
        allowed_tools = [
            "read_file",
            "search_files",
            "file_structure",
            "report_scores",
            "report_flag",
            "report_claims",
        ]
        for tool in allowed_tools:
            with self.subTest(tool=tool):
                allowed, reason = guard.check_tool_call(tool, {}, session_id="role:code:sub_123")
                self.assertTrue(allowed, f"Tool {tool} should be allowed for role 'code', but got: {reason}")
                self.assertIsNone(reason)

    def test_fail_closed_on_unknown_role(self):
        allowed, reason = guard.check_tool_call("read_file", {}, session_id="role:unknown_hacker:1")
        self.assertFalse(allowed)
        self.assertIn("unknown role", reason.lower())

    def test_fail_closed_on_missing_session_id(self):
        allowed, reason = guard.check_tool_call("read_file", {}, session_id=None)
        self.assertFalse(allowed)
        self.assertIn("session", reason.lower())

    def test_deny_writes_outside_run_directory(self):
        allowed, reason = guard.check_file_access("/etc/passwd", session_id="role:code:run_99", is_write=True)
        self.assertFalse(allowed)
        self.assertIn("outside", reason.lower())


if __name__ == "__main__":
    unittest.main()
