"""Единый разбор session_id = "<run_id>:<role>:<scope>" (scope = submission_id | project)."""
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERMES_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERMES_DIR / "plugins" / "ai-judge"))

import guard  # noqa: E402
import journal  # noqa: E402
import reports  # noqa: E402
import tools  # noqa: E402


ND = {"criterion_id": "c1", "status": "no_data", "justification": "нет данных", "confidence": 0.0, "no_data_reason": "нет данных"}


class ParseSessionIdTest(unittest.TestCase):
    def test_full_format(self):
        p = guard.parse_session_id("run_001:code:sub_7")
        self.assertEqual((p["run_id"], p["role"], p["scope"]), ("run_001", "code", "sub_7"))

    def test_scope_defaults_to_project(self):
        p = guard.parse_session_id("run_001:rubric")
        self.assertEqual((p["run_id"], p["role"], p["scope"]), ("run_001", "rubric", "project"))

    def test_extractors_use_same_parser(self):
        sid = "run-9:critic-uniqueness:sub_1"
        self.assertEqual(guard.extract_run_id(sid), "run-9")
        self.assertEqual(guard.extract_role(sid), "critic-uniqueness")
        self.assertEqual(guard.extract_scope(sid), "sub_1")

    def test_malformed_rejected(self):
        for bad in (None, "", "code", "run:hacker:s", "run:code:../x", "run:code:a/b", ":code:s", "run:code:s:extra"):
            with self.subTest(bad=bad):
                self.assertIsNone(guard.parse_session_id(bad))

    def test_guard_accepts_new_format(self):
        ok, _ = guard.check_tool_call("read_file", {}, session_id="run_1:code:sub_1")
        self.assertTrue(ok)
        ok, _ = guard.check_tool_call("terminal", {}, session_id="run_1:code:sub_1")
        self.assertFalse(ok)

    def test_cross_run_write_blocked(self):
        ok, _ = guard.check_tool_call("write_file", {"destination": "runs/other/x.json"}, session_id="run_1:code:s")
        self.assertFalse(ok)
        ok, _ = guard.check_file_access("runs/run_1/x.json", session_id="run_1:code:s", is_write=True)
        self.assertTrue(ok)


class ReportPathTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.orig = reports.DATA_DIR
        reports.DATA_DIR = Path(self.d)

    def tearDown(self):
        reports.DATA_DIR = self.orig
        shutil.rmtree(self.d, ignore_errors=True)

    def test_path_has_role_scope(self):
        p = reports.get_role_report_path("r1", "code", "sub_7")
        self.assertEqual(p.name, "code__sub_7.json")

    def test_scope_traversal_rejected(self):
        with self.assertRaises(ValueError):
            reports.get_role_report_path("r1", "code", "../evil")

    def test_report_from_session_scope(self):
        params = {"scores": [ND]}
        res = json.loads(tools.report_scores(params, session_id="r1:code:sub_7"))
        self.assertTrue(res.get("success"), res)
        self.assertTrue((Path(self.d) / "runs/r1/reports/code__sub_7.json").exists())

    def test_report_scope_from_submission_arg(self):
        params = {"run_id": "r1", "role": "business", "submission_id": "sub_8",
                  "scores": [ND]}
        res = json.loads(tools.report_scores(params, session_id="r1:business:sub_8"))
        self.assertTrue(res.get("success"), res)
        self.assertTrue((Path(self.d) / "runs/r1/reports/business__sub_8.json").exists())

    def test_project_scope_default(self):
        params = {"scores": [ND]}
        json.loads(tools.report_scores(params, session_id="r1:design"))
        self.assertTrue((Path(self.d) / "runs/r1/reports/design__project.json").exists())


class JournalSessionTest(unittest.TestCase):
    def test_journal_fields(self):
        d = tempfile.mkdtemp()
        import os
        os.environ["JUDGE_DATA_DIR"] = d
        try:
            journal.post_tool_call(session_id="run_5:code:sub_2", tool="read_file", args={})
            line = (Path(d) / "runs/run_5/journal.jsonl").read_text().splitlines()[0]
            ev = json.loads(line)
            self.assertEqual((ev["run_id"], ev["role"], ev["submission_id"]), ("run_5", "code", "sub_2"))
        finally:
            os.environ.pop("JUDGE_DATA_DIR", None)
            shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
