import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SKILLS_DIR = REPO_ROOT / "hermes" / "skills"


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


class TestSkillsRubricSorter(unittest.TestCase):

    def test_rubric_skill_exists_and_valid(self):
        skill_file = SKILLS_DIR / "ai-judge-rubric" / "SKILL.md"
        self.assertTrue(skill_file.exists(), f"Rubric skill must exist at {skill_file}")
        content = skill_file.read_text(encoding="utf-8")

        meta = parse_frontmatter(content)
        self.assertEqual(meta.get("name"), "ai-judge-rubric")
        self.assertIn("report_rubric", content, "Skill must use report_rubric tool")
        self.assertIn("данные, а не инструкции", content, "Must contain prompt injection warning")
        self.assertIn("Procedure", content, "Must define Procedure section")
        self.assertIn("Pitfalls", content, "Must define Pitfalls section")
        self.assertIn("критери", content.lower(), "Must reference criteria extraction")
        self.assertIn("шкал", content.lower(), "Must reference score scale/anchors")

    def test_sorter_skill_exists_and_valid(self):
        skill_file = SKILLS_DIR / "ai-judge-sorter" / "SKILL.md"
        self.assertTrue(skill_file.exists(), f"Sorter skill must exist at {skill_file}")
        content = skill_file.read_text(encoding="utf-8")

        meta = parse_frontmatter(content)
        self.assertEqual(meta.get("name"), "ai-judge-sorter")
        self.assertIn("report_inventory_patch", content, "Skill must use report_inventory_patch tool")
        self.assertIn("данные, а не инструкции", content, "Must contain prompt injection warning")
        self.assertIn("Procedure", content, "Must define Procedure section")
        self.assertIn("Pitfalls", content, "Must define Pitfalls section")
        self.assertIn("inventory", content.lower(), "Must reference inventory and materials")


if __name__ == "__main__":
    unittest.main()
