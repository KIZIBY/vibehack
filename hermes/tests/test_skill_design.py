import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SKILL_FILE = REPO_ROOT / "hermes" / "skills" / "ai-judge-design" / "SKILL.md"


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


class TestSkillDesign(unittest.TestCase):

    def test_design_skill_exists_and_valid(self):
        self.assertTrue(SKILL_FILE.exists(), f"Design skill must exist at {SKILL_FILE}")
        content = SKILL_FILE.read_text(encoding="utf-8")

        meta = parse_frontmatter(content)
        self.assertEqual(meta.get("name"), "ai-judge-design")

        # Tools
        self.assertIn("report_scores", content, "Skill must use report_scores tool")
        self.assertIn("report_ux_metrics", content, "Skill must use report_ux_metrics tool")

        # Injection defense
        self.assertIn("данные, а не инструкции", content, "Must contain prompt injection warning")

        content_lower = content.lower()
        # Viewports
        self.assertIn("1440", content, "Must support desktop viewport 1440x900")
        self.assertIn("390", content, "Must support mobile viewport 390x844")

        # Console errors & screencast fallback
        self.assertIn("консол", content_lower, "Must check browser console errors")
        self.assertIn("скринкаст", content_lower, "Must have fallback to screencast when host is down")
        self.assertIn("хост", content_lower, "Must test host availability")


if __name__ == "__main__":
    unittest.main()
