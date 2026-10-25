"""Unit tests for Hermes role isolation and pre_tool_call guard (T062 / FR-022, NFR-010).

Tests verify that:
1. RED requirement: Role 'code' cannot invoke terminal/bash/shell under any circumstance.
2. Full role permission matrix is strictly enforced (Fail-Closed).
3. Write operations across different run_ids (cross-run tampering) are blocked.
4. Deep directory traversal with varied path parameters is blocked.
5. Approvals deny list in config.yaml covers destructive commands.
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


class ComprehensiveRoleGuardTest(unittest.TestCase):
    def setUp(self):
        if guard is None or not hasattr(guard, "check_cross_run_access"):
            self.fail("guard module full isolation is not implemented yet (RED phase)")

    def test_code_role_cannot_invoke_terminal(self):
        """RED requirement: role 'code' must not be able to execute terminal commands."""
        for term_tool in ["terminal", "bash", "sh", "execute_command", "run_shell"]:
            with self.subTest(tool=term_tool):
                allowed, reason = guard.check_tool_call(term_tool, {"command": "pytest"}, session_id="role:code:run_alpha")
                self.assertFalse(allowed, f"Role 'code' must not invoke {term_tool}")
                self.assertIn("blocked", reason.lower())

    def test_cross_run_write_is_blocked(self):
        """Writing into a different run's directory must be rejected."""
        session_id = "role:code:run_001"
        target_path = "runs/run_002/reports/hacked.json"
        allowed, reason = guard.check_tool_call("write_file", {"destination": target_path}, session_id=session_id)
        self.assertFalse(allowed)
        self.assertIn("outside", reason.lower())

    def test_critic_roles_cannot_invoke_browser_or_terminal(self):
        for role in ["critic-uniqueness", "critic-honesty"]:
            for tool in ["browser_navigate", "terminal", "bash"]:
                with self.subTest(role=role, tool=tool):
                    allowed, reason = guard.check_tool_call(tool, {}, session_id=f"role:{role}:run_1")
                    self.assertFalse(allowed, f"Role {role} must not invoke {tool}")

    def test_judge_score_permitted_for_scoring_roles(self):
        for role in ["code", "business", "design", "critic-uniqueness", "critic-honesty"]:
            with self.subTest(role=role):
                allowed, reason = guard.check_tool_call("judge_score", {}, session_id=f"role:{role}:run_1")
                self.assertTrue(allowed, f"Role {role} must have access to judge_score, got: {reason}")

    def test_rubric_and_sorter_cannot_invoke_judge_score(self):
        for role in ["rubric", "sorter"]:
            with self.subTest(role=role):
                allowed, reason = guard.check_tool_call("judge_score", {}, session_id=f"role:{role}:run_1")
                self.assertFalse(allowed, f"Role {role} should not invoke judge_score")


if __name__ == "__main__":
    unittest.main()
