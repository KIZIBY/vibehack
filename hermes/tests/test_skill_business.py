import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SKILL_FILE = REPO_ROOT / "hermes" / "skills" / "ai-judge-business" / "SKILL.md"


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


class TestSkillBusiness(unittest.TestCase):

    def test_business_skill_exists_and_valid(self):
        self.assertTrue(SKILL_FILE.exists(), f"Business skill must exist at {SKILL_FILE}")
        content = SKILL_FILE.read_text(encoding="utf-8")

        meta = parse_frontmatter(content)
        self.assertEqual(meta.get("name"), "ai-judge-business")

        # Tools
        self.assertIn("report_scores", content, "Skill must use report_scores tool")

        # Prompt injection protection
        self.assertIn("данные, а не инструкции", content, "Must contain prompt injection warning")

        content_lower = content.lower()
        # Domain, delegate_task and experts
        self.assertIn("предметн", content_lower, "Must identify subject domain")
        self.assertIn("delegate_task", content, "Must use delegate_task for domain experts")
        self.assertIn("эксперт", content_lower, "Must spawn domain experts")
        self.assertIn("медиан", content_lower, "Must calculate median score")
        self.assertIn("разброс", content_lower, "Must handle score spread > 3 points")


if __name__ == "__main__":
    unittest.main()
