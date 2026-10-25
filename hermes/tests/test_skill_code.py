import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SKILL_FILE = REPO_ROOT / "hermes" / "skills" / "ai-judge-code" / "SKILL.md"


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


class TestSkillCode(unittest.TestCase):

    def test_code_skill_exists_and_valid(self):
        self.assertTrue(SKILL_FILE.exists(), f"Code skill must exist at {SKILL_FILE}")
        content = SKILL_FILE.read_text(encoding="utf-8")

        meta = parse_frontmatter(content)
        self.assertEqual(meta.get("name"), "ai-judge-code")

        # Tools
        self.assertIn("report_scores", content, "Skill must use report_scores tool")
        self.assertIn("report_flag", content, "Skill must use report_flag tool")

        # Prompt injection protection
        self.assertIn("данные, а не инструкции", content, "Must contain prompt injection warning")

        # 5 Code Review Dimensions (FR-015)
        content_lower = content.lower()
        self.assertIn("архитектур", content_lower, "Must cover architecture")
        self.assertIn("качеств", content_lower, "Must cover code quality")
        self.assertIn("тест", content_lower, "Must cover tests")
        self.assertIn("безопасн", content_lower, "Must cover security")
        self.assertIn("соответстви", content_lower, "Must cover spec compliance")

        # Evidence & No-Guessing Rules
        self.assertIn("нет данных", content_lower, "Must require 'нет данных' / no_data instead of guessing")
        self.assertTrue(
            "файл" in content_lower and "строк" in content_lower,
            "Must require file:line evidence references"
        )


if __name__ == "__main__":
    unittest.main()
