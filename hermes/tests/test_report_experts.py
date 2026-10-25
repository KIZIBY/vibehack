"""Плагин: experts для business (контракт agent-report), пути ux-metrics.json / rubric-draft.json."""
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERMES_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERMES_DIR / "plugins" / "ai-judge"))
import reports  # noqa: E402
import schemas  # noqa: E402
import tools  # noqa: E402

SCORE = {"criterion_id": "c1", "status": "no_data", "justification": "нет данных",
         "confidence": 0.0, "no_data_reason": "нет данных"}


class ExpertsTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.orig = reports.DATA_DIR
        reports.DATA_DIR = Path(self.d)

    def tearDown(self):
        reports.DATA_DIR = self.orig
        shutil.rmtree(self.d, ignore_errors=True)

    def test_schema_declares_experts(self):
        self.assertIn("experts", schemas.REPORT_SCORES["parameters"]["properties"])

    def test_experts_saved(self):
        params = {"scores": [SCORE], "experts": [{"name": "Фин-аналитик", "domain": "финтех", "scores": [SCORE]}]}
        res = json.loads(tools.report_scores(params, session_id="r1:business:s1"))
        self.assertTrue(res["success"], res)
        doc = json.loads((Path(self.d) / "runs/r1/reports/business__s1.json").read_text())
        self.assertEqual(doc["experts"][0]["domain"], "финтех")

    def test_experts_rejected_for_other_roles(self):
        params = {"scores": [SCORE], "experts": [{"name": "x", "domain": "y"}]}
        res = json.loads(tools.report_scores(params, session_id="r1:code:s1"))
        self.assertFalse(res["success"])

    def test_experts_bad_shape_rejected(self):
        for bad in ("str", [{"name": "x"}], [{"name": "x", "domain": "y", "scores": [{"criterion_id": "c"}]}]):
            with self.subTest(bad=bad):
                res = json.loads(tools.report_scores({"scores": [SCORE], "experts": bad}, session_id="r1:business:s1"))
                self.assertFalse(res["success"])

    def test_ux_metrics_path_matches_contract(self):
        m = [{"name": "n", "how_to_measure": "h", "good_looks_like": "g"}]
        json.loads(tools.report_ux_metrics({"project_id": "p1", "metrics": m}, session_id="r1:design:project"))
        self.assertTrue((Path(self.d) / "projects/p1/ux-metrics.json").exists())

    def test_rubric_draft_path_matches_contract(self):
        c = [{"name": "n", "description": "d", "weight": 1, "max_score": 10, "agent": "code", "source_ref": {"kind": "file", "ref": "a"}}]
        res = json.loads(tools.report_rubric({"project_id": "p1", "criteria": c}, session_id="r1:rubric:project"))
        self.assertTrue(res.get("success"), res)
        self.assertTrue((Path(self.d) / "projects/p1/rubric-draft.json").exists())


if __name__ == "__main__":
    unittest.main()
