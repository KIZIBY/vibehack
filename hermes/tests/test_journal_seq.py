"""seq журнала монотонен и не обнуляется при нечитаемых строках (backend дедуплицирует по <session_id>#<seq>)."""
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


class JournalSeqTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        os.environ["JUDGE_DATA_DIR"] = self.d
        self.path = Path(self.d) / "runs/r1/journal.jsonl"
        self.path.parent.mkdir(parents=True)

    def tearDown(self):
        os.environ.pop("JUDGE_DATA_DIR", None)
        shutil.rmtree(self.d, ignore_errors=True)

    def seqs(self):
        out = []
        for raw in self.path.read_bytes().split(b"\n"):
            if raw.strip():
                try:
                    out.append(json.loads(raw.decode("utf-8")).get("seq"))
                except ValueError:
                    out.append(None)
        return out

    def test_seq_continues_after_non_utf8_line(self):
        good = json.dumps({"run_id": "r1", "seq": 0}).encode()
        self.path.write_bytes(good + b"\n" + b"\xff\xfe broken \x80\n" + good.replace(b'"seq": 0', b'"seq": 2') + b"\n")
        journal.append_journal_event({"run_id": "r1", "event": "x"})
        journal.append_journal_event({"run_id": "r1", "event": "y"})
        self.assertEqual(self.seqs()[-2:], [3, 4])

    def test_seq_counts_every_line_even_with_unicode_separators(self):
        line = json.dumps({"run_id": "r1", "seq": 0, "note": "a b"}, ensure_ascii=False).encode()
        self.path.write_bytes(line + b"\n")
        journal.append_journal_event({"run_id": "r1", "event": "x"})
        self.assertEqual(self.seqs()[-1], 1)

    def test_blank_lines_not_counted_and_missing_trailing_newline(self):
        self.path.write_bytes(b'{"seq": 0}\n\n{"seq": 1}')
        journal.append_journal_event({"run_id": "r1", "event": "x"})
        self.assertEqual(self.seqs()[-1], 2)
        self.assertTrue(self.path.read_bytes().endswith(b"\n"))
        self.assertEqual(self.path.read_bytes().count(b"\n"), 4)

    def test_unreadable_journal_never_resets_to_zero(self):
        self.path.mkdir()  # чтение файла невозможно
        with self.assertRaises(Exception):
            journal.append_journal_event({"run_id": "r1", "event": "x"})


if __name__ == "__main__":
    unittest.main()
