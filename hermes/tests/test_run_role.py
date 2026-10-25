import os
import sys
import json
import unittest
import subprocess
import shutil
import tempfile
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
HERMES_DIR = REPO_ROOT / "hermes"
SCRIPTS_DIR = HERMES_DIR / "scripts"
RUN_ROLE_SCRIPT = SCRIPTS_DIR / "run_role.sh"
RUN_ROLE_PY = SCRIPTS_DIR / "run_role.py"


class MockHermesHandler(BaseHTTPRequestHandler):
    runs = {}
    polls = {}
    auth_received = []
    idempotency_received = []

    def log_message(self, format, *args):
        # silence HTTP logging in tests
        pass

    def do_POST(self):
        if self.path == "/v1/runs":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode("utf-8")
            data = json.loads(body) if body else {}

            auth = self.headers.get("Authorization", "")
            MockHermesHandler.auth_received.append(auth)
            idem = self.headers.get("Idempotency-Key", "")
            MockHermesHandler.idempotency_received.append(idem)

            run_id = data.get("session_id", "run-default:code").split(":")[0]
            existing = MockHermesHandler.runs.get(run_id)
            if existing and existing.get("status") == "failed":
                run_obj = existing
            else:
                run_obj = {
                    "id": run_id,
                    "session_id": data.get("session_id", ""),
                    "status": "running",
                    "instructions": data.get("instructions", ""),
                    "input": data.get("input", "")
                }
                MockHermesHandler.runs[run_id] = run_obj
                MockHermesHandler.polls[run_id] = 0

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(run_obj).encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        if self.path.startswith("/v1/runs/"):
            run_id = self.path.split("/v1/runs/")[-1]
            if run_id in MockHermesHandler.runs:
                MockHermesHandler.polls[run_id] = MockHermesHandler.polls.get(run_id, 0) + 1
                poll_count = MockHermesHandler.polls[run_id]
                run_obj = dict(MockHermesHandler.runs[run_id])
                if run_obj.get("status") != "failed":
                    # Complete after first poll unless configured otherwise
                    if poll_count >= 2:
                        run_obj["status"] = "completed"
                        run_obj["usage"] = {"prompt_tokens": 120, "completion_tokens": 45}
                    else:
                        run_obj["status"] = "running"

                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(run_obj).encode("utf-8"))
            else:
                self.send_response(404)
                self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()


class TestRunRoleContract(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        MockHermesHandler.runs.clear()
        MockHermesHandler.polls.clear()
        MockHermesHandler.auth_received.clear()
        MockHermesHandler.idempotency_received.clear()

        cls.server = HTTPServer(("127.0.0.1", 0), MockHermesHandler)
        cls.port = cls.server.server_port
        cls.server_thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.server_thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        MockHermesHandler.runs.clear()
        MockHermesHandler.polls.clear()
        MockHermesHandler.auth_received.clear()
        MockHermesHandler.idempotency_received.clear()

    def test_run_role_script_exists(self):
        self.assertTrue(RUN_ROLE_SCRIPT.exists(), f"run_role.sh must exist at {RUN_ROLE_SCRIPT}")

    def test_run_role_args_validation(self):
        """Missing role or workdir must exit with code 2."""
        proc = subprocess.run(
            [sys.executable, str(RUN_ROLE_PY)],
            capture_output=True,
            text=True
        )
        self.assertEqual(proc.returncode, 2, f"Expected code 2 on missing args, got {proc.returncode}: {proc.stderr}")

    def test_run_role_successful_execution(self):
        """Successful run role execution polls status, writes/checks report, prints path."""
        run_id = "test-run-smoke-1"
        fixture_dir = REPO_ROOT / "tests" / "fixtures" / "workspaces"
        tmp = tempfile.mkdtemp(prefix="run_role_")
        self.addCleanup(shutil.rmtree, tmp, True)
        data_dir = Path(tmp) / "workspaces"
        shutil.copytree(fixture_dir, data_dir)
        report_dir = data_dir / "runs" / run_id / "reports"
        report_dir.mkdir(parents=True, exist_ok=True)
        report_file = report_dir / "code.json"

        # Pre-seed report conforming to agent-report.schema.json
        sample_report = {
            "schema_version": "1",
            "kind": "scores",
            "run_id": run_id,
            "role": "code",
            "scores": [
                {
                    "criterion_id": "tech_quality",
                    "status": "scored",
                    "score": 8,
                    "max_score": 10,
                    "confidence": "high",
                    "justification": "Clean architecture and modular code layout.",
                    "evidence": [
                        {
                            "kind": "file",
                            "ref": "extracted/repo/main.py:1-50",
                            "quote": "Modular implementation"
                        }
                    ]
                }
            ]
        }
        report_file.write_text(json.dumps(sample_report, ensure_ascii=False, indent=2), encoding="utf-8")

        workdir = "submissions/sample_work"

        env = os.environ.copy()
        env["HERMES_API_URL"] = f"http://127.0.0.1:{self.port}"
        env["API_SERVER_KEY"] = "secret-token-xyz"
        env["JUDGE_DATA_DIR"] = str(data_dir)
        env["RUN_ID"] = run_id
        env["POLL_INTERVAL"] = "0.05"

        proc = subprocess.run(
            [sys.executable, str(RUN_ROLE_PY), "code", workdir],
            capture_output=True,
            text=True,
            env=env
        )

        self.assertEqual(proc.returncode, 0, f"run_role failed: {proc.stderr}\nstdout: {proc.stdout}")
        self.assertIn("code.json", proc.stdout)
        self.assertIn(f"runs/{run_id}/reports/code.json", proc.stdout.replace("\\", "/"))

        # Verify auth and idempotency
        self.assertTrue(any("secret-token-xyz" in h for h in MockHermesHandler.auth_received))
        self.assertTrue(len(MockHermesHandler.idempotency_received) > 0)

    def test_run_role_failed_status(self):
        """When Hermes returns terminal status failed, exit with non-zero."""
        run_id = "test-run-fail-1"
        fixture_dir = REPO_ROOT / "tests" / "fixtures" / "workspaces"
        tmp = tempfile.mkdtemp(prefix="run_role_")
        self.addCleanup(shutil.rmtree, tmp, True)
        data_dir = Path(tmp) / "workspaces"
        shutil.copytree(fixture_dir, data_dir)

        env = os.environ.copy()
        env["HERMES_API_URL"] = f"http://127.0.0.1:{self.port}"
        env["JUDGE_DATA_DIR"] = str(data_dir)
        env["RUN_ID"] = run_id
        env["POLL_INTERVAL"] = "0.05"

        # Configure handler to return status 'failed'
        MockHermesHandler.runs[run_id] = {
            "id": run_id,
            "session_id": f"{run_id}:code",
            "status": "failed",
            "error": "Execution aborted due to syntax error in input"
        }
        MockHermesHandler.polls[run_id] = 5

        proc = subprocess.run(
            [sys.executable, str(RUN_ROLE_PY), "code", "submissions/sample_work"],
            capture_output=True,
            text=True,
            env=env
        )

        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("failed", proc.stderr.lower() + proc.stdout.lower())


if __name__ == "__main__":
    unittest.main()
