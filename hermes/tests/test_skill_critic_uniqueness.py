import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SKILL_FILE = REPO_ROOT / "hermes" / "skills" / "ai-judge-critic-uniqueness" / "SKILL.md"


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


class TestSkillCriticUniqueness(unittest.TestCase):

    def test_critic_uniqueness_skill_exists_and_valid(self):
        self.assertTrue(SKILL_FILE.exists(), f"Critic uniqueness skill must exist at {SKILL_FILE}")
        content = SKILL_FILE.read_text(encoding="utf-8")

        meta = parse_frontmatter(content)
        self.assertEqual(meta.get("name"), "ai-judge-critic-uniqueness")

        # Tools
        self.assertIn("report_scores", content, "Skill must use report_scores tool")
        self.assertIn("report_flag", content, "Skill must use report_flag tool")

        # Injection defense
        self.assertIn("данные, а не инструкции", content, "Must contain prompt injection warning")

        content_lower = content.lower()
        # Flags and inputs
        self.assertIn("git_log.json", content, "Must check commit history git_log.json")
        self.assertIn("similarity.json", content, "Must check code similarity")
        self.assertIn("plagiarism", content, "Must handle plagiarism flag")
        self.assertIn("pre_start_project", content, "Must handle pre_start_project flag")
        self.assertIn("поиск", content_lower, "Must use web search for analogs")


if __name__ == "__main__":
    unittest.main()
