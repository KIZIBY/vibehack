"""Изоляция отчётов: run_id/role/scope берутся только из session_id, модель их не подменяет (ревью P1)."""
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERMES_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERMES_DIR / "plugins" / "ai-judge"))
import journal  # noqa: E402
import reports  # noqa: E402
import tools  # noqa: E402

ND = {"criterion_id": "c1", "status": "no_data", "justification": "нет данных", "confidence": 0.0,
      "no_data_reason": "нет данных"}
FLAG = {"type": "plagiarism", "confidence": 0.5, "note": "n", "evidence": [{"kind": "url", "ref": "http://x"}]}
CLAIM = {"claim_id": "k1", "text": "t", "source_ref": {"kind": "slide", "ref": "d.pdf#1"},
         "verdict": "not_found", "evidence": []}
SID = "r1:code:s1"


class IsolationTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.orig = reports.DATA_DIR
        reports.DATA_DIR = Path(self.d)

    def tearDown(self):
        reports.DATA_DIR = self.orig
        shutil.rmtree(self.d, ignore_errors=True)

    def _no_files(self):
        self.assertEqual([p for p in Path(self.d).rglob("*.json")], [])

    def test_scores_foreign_fields_refused(self):
        for extra in ({"run_id": "r2"}, {"role": "business"}, {"submission_id": "s2"}):
            with self.subTest(extra=extra):
                res = json.loads(tools.report_scores({"scores": [ND], **extra}, session_id=SID))
                self.assertFalse(res["success"], res)
        self._no_files()

    def test_flag_foreign_fields_refused(self):
        for extra in ({"run_id": "r2"}, {"role": "business"}, {"submission_id": "s2"}):
            with self.subTest(extra=extra):
                res = json.loads(tools.report_flag({"flag": FLAG, **extra}, session_id="r1:critic-uniqueness:s1"))
                self.assertFalse(res["success"], res)
        self._no_files()

    def test_claims_foreign_fields_refused(self):
        for extra in ({"run_id": "r2"}, {"role": "code"}, {"submission_id": "s2"}):
            with self.subTest(extra=extra):
                res = json.loads(tools.report_claims({"claims": [CLAIM], **extra}, session_id="r1:critic-honesty:s1"))
                self.assertFalse(res["success"], res)
        self._no_files()

    def test_matching_fields_accepted(self):
        res = json.loads(tools.report_scores(
            {"scores": [ND], "run_id": "r1", "role": "code", "submission_id": "s1"}, session_id=SID))
        self.assertTrue(res["success"], res)

    def test_missing_or_bad_session_refused(self):
        for sid in (None, "", "garbage", "r1:hacker:s1"):
            with self.subTest(sid=sid):
                res = json.loads(tools.report_scores({"scores": [ND], "run_id": "r1", "role": "code"}, session_id=sid))
                self.assertFalse(res["success"])

    def test_project_scope_refused_for_scoring_tools(self):
        for fn, params, sid in (
            (tools.report_scores, {"scores": [ND]}, "r1:code"),
            (tools.report_flag, {"flag": FLAG}, "r1:critic-uniqueness:project"),
            (tools.report_claims, {"claims": [CLAIM]}, "r1:critic-honesty"),
        ):
            with self.subTest(fn=fn.__name__):
                self.assertFalse(json.loads(fn(params, session_id=sid))["success"])

    def test_inventory_patch_run_id_from_session_only(self):
        res = json.loads(tools.report_inventory_patch({"updates": [{"x": 1}], "run_id": "r2"}, session_id="r1:sorter:s1"))
        self.assertFalse(res["success"])

    def test_unsafe_project_id_refused(self):
        m = [{"name": "n", "how_to_measure": "h", "good_looks_like": "g"}]
        res = json.loads(tools.report_ux_metrics({"project_id": "../../x", "metrics": m}, session_id="r1:design:s1"))
        self.assertFalse(res["success"])


class JournalSafetyTest(unittest.TestCase):
    def test_unsafe_run_id_writes_nothing(self):
        d = tempfile.mkdtemp()
        os.environ["JUDGE_DATA_DIR"] = d
        try:
            journal.post_tool_call(session_id="../../evil:code:s1", tool="read_file", args={})
            journal.append_journal_event({"run_id": "../escape", "event": "x"})
            self.assertEqual(list(Path(d).rglob("journal.jsonl")), [])
            self.assertFalse((Path(d).parent / "escape").exists())
        finally:
            os.environ.pop("JUDGE_DATA_DIR", None)
            shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
