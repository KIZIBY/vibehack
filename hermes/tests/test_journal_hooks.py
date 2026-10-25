import os
import sys
import json
import shutil
import tempfile
import unittest
import threading
from pathlib import Path

HERMES_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERMES_DIR / "plugins" / "ai-judge"))

try:
    import journal
except ImportError:
    journal = None


class TestJournalHooks(unittest.TestCase):

    def setUp(self):
        if journal is None or not hasattr(journal, "post_tool_call"):
            self.fail("hermes.plugins.ai-judge.journal module or post_tool_call hook not found")
        self.test_dir = tempfile.mkdtemp(prefix="test_journal_")
        self.run_id = "run-test-journal-1"
        self.session_id = f"{self.run_id}:code"
        self.run_dir = Path(self.test_dir) / "runs" / self.run_id
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.journal_file = self.run_dir / "journal.jsonl"
        os.environ["JUDGE_DATA_DIR"] = self.test_dir

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)
        if "JUDGE_DATA_DIR" in os.environ:
            del os.environ["JUDGE_DATA_DIR"]

    def test_post_tool_call_appends_valid_event(self):
        """post_tool_call writes a valid journal line conforming to journal-event.schema.json."""
        journal.post_tool_call(
            session_id=self.session_id,
            tool="read_file",
            args={"path": "extracted/repo/main.py"},
            result={"content": "def main(): pass"},
            duration_ms=45,
            project_id="proj-1",
            submission_id="sub-1"
        )

        self.assertTrue(self.journal_file.exists(), "journal.jsonl must be created")
        lines = [json.loads(line) for line in self.journal_file.read_text(encoding="utf-8").strip().splitlines()]
        self.assertEqual(len(lines), 1)

        event = lines[0]
        self.assertEqual(event["schema_version"], "1")
        self.assertEqual(event["run_id"], self.run_id)
        self.assertEqual(event["role"], "code")
        self.assertEqual(event["session_id"], self.session_id)
        self.assertEqual(event["event"], "tool_call")
        self.assertEqual(event["source"], "hermes.post_tool_call")
        self.assertEqual(event["seq"], 0)
        self.assertIn("extracted/repo/main.py", event["args_summary"])

    def test_secret_masking_in_summaries(self):
        """Secrets like Bearer tokens or API keys must be masked in args and result summaries."""
        secret_args = {
            "token": "sk-1234567890abcdef1234567890abcdef",
            "auth": "Bearer secret_jwt_token_here_xyz",
            "password": "super_secret_password_123"
        }
        journal.post_tool_call(
            session_id=self.session_id,
            tool="fetch_repo",
            args=secret_args,
            result={"status": "ok", "key": "ghp" + "_" + "1234567890" * 3 + "123456"},
            project_id="proj-1"
        )

        lines = [json.loads(line) for line in self.journal_file.read_text(encoding="utf-8").strip().splitlines()]
        event = lines[0]
        args_str = event["args_summary"]
        res_str = event["result_summary"]

        self.assertNotIn("sk-1234567890abcdef", args_str)
        self.assertNotIn("secret_jwt_token_here_xyz", args_str)
        self.assertNotIn("super_secret_password_123", args_str)
        self.assertNotIn("ghp_1234567890", res_str)
        self.assertIn("[MASKED]", args_str)

    def test_post_llm_call_without_tokens_leaves_null(self):
        """Tokens and cost must be null if provider gave no data (NFR-008)."""
        journal.post_llm_call(
            session_id=self.session_id,
            model="codex",
            provider="openai-codex",
            duration_ms=1200,
            project_id="proj-1"
        )

        lines = [json.loads(line) for line in self.journal_file.read_text(encoding="utf-8").strip().splitlines()]
        event = lines[0]
        self.assertEqual(event["event"], "model_call")
        self.assertEqual(event["source"], "hermes.post_llm_call")
        self.assertIsNone(event["tokens_in"])
        self.assertIsNone(event["tokens_out"])
        self.assertIsNone(event["cost_usd"])

    def test_concurrent_writes_no_duplicate_or_lost_seq(self):
        """Parallel writes must not lose or duplicate seq numbers."""
        num_threads = 10
        events_per_thread = 5
        total_events = num_threads * events_per_thread

        def worker(t_idx):
            for i in range(events_per_thread):
                journal.post_tool_call(
                    session_id=self.session_id,
                    tool=f"tool_t{t_idx}_{i}",
                    args={"idx": i},
                    result={"ok": True},
                    project_id="proj-1"
                )

        threads = [threading.Thread(target=worker, args=(t,)) for t in range(num_threads)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        lines = [json.loads(line) for line in self.journal_file.read_text(encoding="utf-8").strip().splitlines()]
        self.assertEqual(len(lines), total_events, f"Expected {total_events} events, found {len(lines)}")

        seqs = [e["seq"] for e in lines]
        self.assertEqual(len(seqs), len(set(seqs)), "seq values must be unique (no duplicates)")
        self.assertEqual(sorted(seqs), list(range(total_events)), "seq values must form a continuous sequence from 0 to N-1")


if __name__ == "__main__":
    unittest.main()
