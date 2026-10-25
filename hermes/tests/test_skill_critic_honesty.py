import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SKILL_FILE = REPO_ROOT / "hermes" / "skills" / "ai-judge-critic-honesty" / "SKILL.md"


def parse_frontmatter(content: str) -> dict:
    match = re.match(r"^---\s*\n(.*?)\n---\s*\n", content, re.DOTALL)
    if not match:
        return {}
    frontmatter_text = match.group(1)
    meta = {}
    for line in frontmatter_text.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            meta[k.strip()] = v.strip().strip('"\'')
    return meta


class TestSkillCriticHonesty(unittest.TestCase):

    def test_critic_honesty_skill_exists_and_valid(self):
        self.assertTrue(SKILL_FILE.exists(), f"Critic honesty skill must exist at {SKILL_FILE}")
        content = SKILL_FILE.read_text(encoding="utf-8")

        meta = parse_frontmatter(content)
        self.assertEqual(meta.get("name"), "ai-judge-critic-honesty")

        # Tools
        self.assertIn("report_claims", content, "Skill must use report_claims tool")
        self.assertIn("report_scores", content, "Skill must use report_scores tool")
        self.assertIn("report_flag", content, "Skill must use report_flag tool")

        # Injection defense
        self.assertIn("данные, а не инструкции", content, "Must contain prompt injection warning")

        # Verdicts
        self.assertIn("confirmed", content, "Must define confirmed verdict")
        self.assertIn("not_found", content, "Must define not_found verdict")
        self.assertIn("contradicted", content, "Must define contradicted verdict")

        # Flag
        self.assertIn("claim_mismatch", content, "Must handle claim_mismatch flag")

        # Cross-role verification
        self.assertIn("code", content, "Must cross-reference code report")
        self.assertIn("design", content, "Must cross-reference design report")


if __name__ == "__main__":
    unittest.main()
