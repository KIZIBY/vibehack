"""T065–T068: навыки business, design, critic-uniqueness, critic-honesty + белые списки инструментов."""
import re
import sys
import unittest
from pathlib import Path

HERMES_DIR = Path(__file__).resolve().parent.parent
SKILLS = HERMES_DIR / "skills"
sys.path.insert(0, str(HERMES_DIR / "plugins" / "ai-judge"))
import guard  # noqa: E402

TERMINAL = {"terminal", "bash", "sh", "execute_command", "run_shell", "process_spawn", "exec"}

# роль -> (каталог навыка, обязательные подстроки в нижнем регистре)
SPECIFIC = {
    "business": ("ai-judge-business", ["delegate_task", "медиан", "3", "предметн", "эксперт", "experts"]),
    "design": ("ai-judge-design", ["report_ux_metrics", "1440", "900", "390", "844", "консол", "скриншот",
                                    "скринкаст", "[спайк]", "browser_navigate"]),
    "critic-uniqueness": ("ai-judge-critic-uniqueness", ["git_log.json", "similarity.json", "plagiarism",
                                                         "pre_start_project", "web_search", "уверенност"]),
    "critic-honesty": ("ai-judge-critic-honesty", ["report_claims", "confirmed", "not_found", "contradicted",
                                                   "claim_mismatch", "презентаци", "расшифровк"]),
}
COMMON = ["данные, а не инструкции", "нет данных", "no_data", "evidence", "report_scores", "prompt_injection"]


def frontmatter(text):
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n", text, re.DOTALL)
    meta = {}
    if m:
        for line in m.group(1).splitlines():
            if ":" in line and not line.startswith(" "):
                k, v = line.split(":", 1)
                meta[k.strip()] = v.strip()
    return meta


class JudgeSkillsTest(unittest.TestCase):
    def test_each_skill(self):
        for role, (dirname, needles) in SPECIFIC.items():
            with self.subTest(role=role):
                f = SKILLS / dirname / "SKILL.md"
                self.assertTrue(f.exists(), f"нет {f}")
                text = f.read_text(encoding="utf-8")
                self.assertEqual(frontmatter(text).get("name"), dirname)
                low = text.lower()
                for n in COMMON + needles:
                    self.assertIn(n.lower(), low, f"{dirname}: нет '{n}'")
                for tool in TERMINAL:
                    self.assertNotRegex(low, rf"вызов\w*\s+`?{tool}`?\b", f"{dirname}: советует терминал")

    def test_confidence_is_number_not_label(self):
        for dirname, _ in SPECIFIC.values():
            text = (SKILLS / dirname / "SKILL.md").read_text(encoding="utf-8")
            self.assertNotIn('"low" | "medium" | "high"', text)
            self.assertRegex(text, r"confidence[^\n]*0[.,]?\d*[–-]\s*1|0\.0[–-]1\.0|от 0 до 1")

    def test_code_skill_confidence_fixed(self):
        text = (SKILLS / "ai-judge-code" / "SKILL.md").read_text(encoding="utf-8")
        self.assertNotIn('"low" | "medium" | "high"', text)

    def test_roles_without_terminal(self):
        for role in guard.ROLE_ALLOWED_TOOLS:
            with self.subTest(role=role):
                self.assertFalse(guard.ROLE_ALLOWED_TOOLS[role] & TERMINAL)
                for t in TERMINAL:
                    ok, _ = guard.check_tool_call(t, {}, session_id=f"r1:{role}:s1")
                    self.assertFalse(ok)

    def test_critics_cannot_browse_or_delegate(self):
        for role in ("critic-uniqueness", "critic-honesty", "code"):
            for t in ("browser_navigate", "delegate_task", "write_file", "execute_code"):
                ok, _ = guard.check_tool_call(t, {}, session_id=f"r1:{role}:s1")
                self.assertFalse(ok, f"{role} не должен иметь {t}")

    def test_design_has_ux_metrics_tool_business_has_delegate(self):
        ok, _ = guard.check_tool_call("report_ux_metrics", {}, session_id="r1:design:project")
        self.assertTrue(ok)
        ok, _ = guard.check_tool_call("delegate_task", {}, session_id="r1:business:s1")
        self.assertTrue(ok)
        ok, _ = guard.check_tool_call("report_ux_metrics", {}, session_id="r1:business:s1")
        self.assertFalse(ok)


if __name__ == "__main__":
    unittest.main()
