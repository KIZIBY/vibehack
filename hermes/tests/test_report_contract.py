"""Плагин принимает только то, что примет backend по agent-report.schema.json (ревью P1) + однократные метрики UX."""
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERMES_DIR = Path(__file__).resolve().parent.parent
REPO = HERMES_DIR.parent
sys.path.insert(0, str(HERMES_DIR / "plugins" / "ai-judge"))
sys.path.insert(0, str(HERMES_DIR / "evals"))
import metrics  # noqa: E402
import reports  # noqa: E402
import tools  # noqa: E402

try:
    import jsonschema
except ImportError:  # pragma: no cover
    jsonschema = None

SCHEMA = json.loads((REPO / "specs/001-ai-judge-platform/contracts/agent-report.schema.json").read_text(encoding="utf-8"))
EV = {"kind": "file", "ref": "a.py:1-2", "quote": "q"}
SC = {"criterion_id": "c1", "status": "scored", "score": 5, "max_score": 10, "justification": "j",
      "confidence": 0.5, "evidence": [EV]}
FLAG = {"type": "plagiarism", "confidence": 0.5, "note": "n", "evidence": [EV]}
CLAIM = {"claim_id": "k1", "text": "t", "source_ref": {"kind": "slide", "ref": "d.pdf#1"},
         "verdict": "confirmed", "evidence": [EV]}


class ContractStrictnessTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.orig = reports.DATA_DIR
        reports.DATA_DIR = Path(self.d)

    def tearDown(self):
        reports.DATA_DIR = self.orig
        shutil.rmtree(self.d, ignore_errors=True)

    def scores(self, **over):
        return json.loads(tools.report_scores({"scores": [dict(SC, **over)]}, session_id="r1:code:s1"))["success"]

    def test_bad_scores_rejected(self):
        bad = [{"confidence": True}, {"score": True}, {"score": float("inf")}, {"confidence": float("nan")},
               {"justification": "x" * 3001}, {"extra": 1}, {"evidence": [dict(EV, extra=1)]},
               {"evidence": [dict(EV, quote="q" * 501)]}, {"max_score": 0}]
        for over in bad:
            with self.subTest(over=str(over)[:40]):
                self.assertFalse(self.scores(**over))

    def test_good_score_accepted(self):
        self.assertTrue(self.scores())

    def test_summary_limit(self):
        res = json.loads(tools.report_scores({"scores": [SC], "summary": "x" * 3001}, session_id="r1:code:s1"))
        self.assertFalse(res["success"])

    def test_bad_flags_rejected(self):
        for over in ({"note": "x" * 1501}, {"extra": 1}, {"confidence": True}, {"evidence": [dict(EV, kind="bad")]}):
            with self.subTest(over=str(over)[:40]):
                res = json.loads(tools.report_flag({"flag": dict(FLAG, **over)}, session_id="r1:critic-uniqueness:s1"))
                self.assertFalse(res["success"])

    def test_bad_claims_rejected(self):
        bad = [{"source_ref": None}, {"text": "x" * 501}, {"extra": 1}, {"claim_id": 5},
               {"source_ref": {"kind": "slide"}}, {"evidence": [dict(EV, extra=1)]}]
        for over in bad:
            with self.subTest(over=str(over)[:40]):
                res = json.loads(tools.report_claims({"claims": [dict(CLAIM, **over)]}, session_id="r1:critic-honesty:s1"))
                self.assertFalse(res["success"])

    def test_claim_without_source_ref_key_rejected(self):
        c = dict(CLAIM)
        del c["source_ref"]
        res = json.loads(tools.report_claims({"claims": [c]}, session_id="r1:critic-honesty:s1"))
        self.assertFalse(res["success"])

    def test_experts_extra_fields_rejected(self):
        ex = [{"name": "n", "domain": "d", "scores": [dict(SC, extra=1)]}]
        res = json.loads(tools.report_scores({"scores": [SC], "experts": ex}, session_id="r1:business:s1"))
        self.assertFalse(res["success"])

    @unittest.skipIf(jsonschema is None, "нет jsonschema")
    def test_accepted_documents_pass_contract_schema(self):
        tools.report_scores({"scores": [SC], "summary": "s"}, session_id="r1:critic-honesty:s1")
        tools.report_flag({"flag": FLAG}, session_id="r1:critic-honesty:s1")
        tools.report_claims({"claims": [CLAIM]}, session_id="r1:critic-honesty:s1")
        tools.report_scores({"scores": [SC], "experts": [{"name": "n", "domain": "d", "scores": [SC]}]},
                            session_id="r1:business:s1")
        for p in (Path(self.d) / "runs/r1/reports").glob("*.json"):
            with self.subTest(p=p.name):
                jsonschema.validate(json.loads(p.read_text(encoding="utf-8")), SCHEMA)


class UxMetricsOnceTest(unittest.TestCase):
    M = [{"name": "n", "how_to_measure": "h", "good_looks_like": "g"}]

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.orig = reports.DATA_DIR
        reports.DATA_DIR = Path(self.d)

    def tearDown(self):
        reports.DATA_DIR = self.orig
        shutil.rmtree(self.d, ignore_errors=True)

    def call(self, sid, pid="p1", metrics=None):
        return json.loads(tools.report_ux_metrics({"project_id": pid, "metrics": metrics or self.M}, session_id=sid))

    def test_only_design_role_project_scope(self):
        self.assertFalse(self.call("r1:design:s1")["success"])
        self.assertFalse(self.call("r1:code:project")["success"])
        self.assertFalse(self.call(None)["success"])
        self.assertTrue(self.call("r1:design:project")["success"])

    def test_second_call_does_not_overwrite(self):
        self.assertTrue(self.call("r1:design:project")["success"])
        other = [{"name": "other", "how_to_measure": "h", "good_looks_like": "g"}]
        res = self.call("r2:design:project", metrics=other)
        self.assertFalse(res["success"])
        saved = json.loads((Path(self.d) / "projects/p1/ux-metrics.json").read_text(encoding="utf-8"))
        self.assertEqual(saved["metrics"][0]["name"], "n")

    def test_extra_metric_fields_rejected(self):
        self.assertFalse(self.call("r1:design:project", metrics=[dict(self.M[0], extra=1)])["success"])


class StabilityFloatTest(unittest.TestCase):
    def test_spread_exactly_tol_is_stable_despite_float_noise(self):
        runs = [{"c": 3.9}, {"c": 4.9}, {"c": 4.4}]
        self.assertEqual(metrics.stability_share(runs, tol=1.0), 1.0)


if __name__ == "__main__":
    unittest.main()
