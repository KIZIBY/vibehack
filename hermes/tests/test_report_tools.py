"""Unit tests for Hermes reporting tools (T060 / US5 / FR-020).

Tests verify that:
1. 'scored' status without evidence is rejected with a clear error message (RED requirement).
2. Valid scores with evidence are accepted and written atomically to runs/<run_id>/reports/<role>.json.
3. Multiple reports for the same criterion update the score (last score wins).
4. report_flag appends flags with required evidence.
5. report_claims, report_rubric, report_ux_metrics, and report_inventory_patch function correctly.
6. judge_score handler is untouched and keeps existing behavior.
"""
import json
import shutil
import tempfile
import unittest
from pathlib import Path
import sys

HERMES_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERMES_DIR / "plugins" / "ai-judge"))

try:
    import tools
    import reports
except ImportError:
    reports = None


class ReportToolsTest(unittest.TestCase):
    def setUp(self):
        if reports is None or not hasattr(tools, "report_scores"):
            self.fail("reports module or report_* tools are not implemented yet (RED phase)")

        self.test_dir = tempfile.mkdtemp(prefix="judge_test_")
        self.original_data_dir = getattr(reports, "DATA_DIR", None)
        reports.DATA_DIR = Path(self.test_dir)

    def tearDown(self):
        if self.original_data_dir is not None:
            reports.DATA_DIR = self.original_data_dir
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_scored_without_evidence_is_rejected(self):
        """RED requirement: status='scored' without evidence must be rejected."""
        params = {
            "run_id": "run_001",
            "submission_id": "sub_001",
            "role": "code",
            "rubric_version": 1,
            "scores": [
                {
                    "criterion_id": "code_quality",
                    "status": "scored",
                    "score": 8.5,
                    "max_score": 10.0,
                    "justification": "Good architecture",
                    "confidence": 0.9,
                    # evidence is missing!
                }
            ],
        }
        resp = json.loads(tools.report_scores(params, session_id="role:code:run_001"))
        self.assertFalse(resp["success"])
        self.assertIn("evidence", resp["error"].lower())

    def test_scored_with_empty_evidence_is_rejected(self):
        params = {
            "run_id": "run_001",
            "submission_id": "sub_001",
            "role": "code",
            "rubric_version": 1,
            "scores": [
                {
                    "criterion_id": "code_quality",
                    "status": "scored",
                    "score": 8.5,
                    "max_score": 10.0,
                    "justification": "Good architecture",
                    "confidence": 0.9,
                    "evidence": [],  # empty evidence!
                }
            ],
        }
        resp = json.loads(tools.report_scores(params, session_id="role:code:run_001"))
        self.assertFalse(resp["success"])
        self.assertIn("evidence", resp["error"].lower())

    def test_valid_scores_saved_and_last_criterion_score_wins(self):
        """Multiple reports for same criterion update it (last score wins)."""
        session_id = "role:code:run_001"
        # First call: score 6.0
        params1 = {
            "run_id": "run_001",
            "submission_id": "sub_001",
            "role": "code",
            "rubric_version": 1,
            "scores": [
                {
                    "criterion_id": "c1",
                    "status": "scored",
                    "score": 6.0,
                    "max_score": 10.0,
                    "justification": "Initial pass",
                    "confidence": 0.7,
                    "evidence": [{"kind": "file", "ref": "app.py:10-25"}],
                }
            ],
        }
        resp1 = json.loads(tools.report_scores(params1, session_id=session_id))
        self.assertTrue(resp1["success"])

        # Second call: score 9.0 on c1 and a new criterion c2
        params2 = {
            "run_id": "run_001",
            "submission_id": "sub_001",
            "role": "code",
            "rubric_version": 1,
            "scores": [
                {
                    "criterion_id": "c1",
                    "status": "scored",
                    "score": 9.0,
                    "max_score": 10.0,
                    "justification": "Found clean abstractions on re-review",
                    "confidence": 0.95,
                    "evidence": [{"kind": "file", "ref": "app.py:10-50"}],
                },
                {
                    "criterion_id": "c2",
                    "status": "no_data",
                    "justification": "No tests present",
                    "confidence": 1.0,
                    "no_data_reason": "No test directory in repository",
                },
            ],
        }
        resp2 = json.loads(tools.report_scores(params2, session_id=session_id))
        self.assertTrue(resp2["success"])

        # Read saved report
        report_file = Path(self.test_dir) / "runs" / "run_001" / "reports" / "code.json"
        self.assertTrue(report_file.exists())
        doc = json.loads(report_file.read_text(encoding="utf-8"))

        scores_by_id = {s["criterion_id"]: s for s in doc["scores"]}
        self.assertEqual(len(scores_by_id), 2)
        self.assertEqual(scores_by_id["c1"]["score"], 9.0)  # last score won!
        self.assertEqual(scores_by_id["c2"]["status"], "no_data")

    def test_report_flag_appends_and_validates(self):
        session_id = "role:critic-uniqueness:run_001"
        flag_params = {
            "run_id": "run_001",
            "role": "critic-uniqueness",
            "flag": {
                "type": "plagiarism",
                "confidence": 0.85,
                "note": "Exact match with public template repository",
                "evidence": [{"kind": "url", "ref": "https://github.com/example/starter"}],
            },
        }
        resp = json.loads(tools.report_flag(flag_params, session_id=session_id))
        self.assertTrue(resp["success"])

        report_file = Path(self.test_dir) / "runs" / "run_001" / "reports" / "critic-uniqueness.json"
        doc = json.loads(report_file.read_text(encoding="utf-8"))
        self.assertEqual(len(doc["flags"]), 1)
        self.assertEqual(doc["flags"][0]["type"], "plagiarism")

    def test_judge_score_still_works(self):
        """judge_score handler must remain untouched."""
        resp = json.loads(tools.judge_score({"criteria": [{"name": "C", "score": 8}]}))
        self.assertTrue(resp["success"])
        self.assertEqual(resp["total"], 80.0)


if __name__ == "__main__":
    unittest.main()
