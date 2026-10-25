"""Unit tests for Hermes deployment configuration & egress security (T069 / I-1, NFR-011).

Tests verify that:
1. config.yaml defines gateway.api_server.max_concurrent_runs == 5.
2. config.yaml defines platform_toolsets.api_server with ai_judge toolset.
3. Network egress blocks internal private networks (SSRF / metadata protection).
4. docker-compose.yml mounts ${JUDGE_DATA_DIR} as /opt/data/workspaces.
5. SOUL.md reflects the objective, evidence-driven judge personality.
"""
import unittest
from pathlib import Path

HERMES_DIR = Path(__file__).resolve().parent.parent


class HermesDeployConfigTest(unittest.TestCase):
    def test_config_yaml_parameters(self):
        config_path = HERMES_DIR / "config" / "config.yaml"
        self.assertTrue(config_path.exists())
        content = config_path.read_text(encoding="utf-8")

        # Concurrency limit from Spike T001 / R4
        self.assertIn("max_concurrent_runs: 5", content, "config.yaml must configure max_concurrent_runs: 5")
        # Toolsets for api_server
        self.assertIn("api_server", content, "config.yaml must configure platform_toolsets.api_server")
        self.assertIn("ai_judge", content, "api_server toolsets must include ai_judge")
        # Egress protection against internal networks (NFR-011, I-1)
        self.assertIn("169.254.169.254", content, "Egress must block cloud metadata IP")
        self.assertIn("127.0.0.0/8", content, "Egress must block localhost")
        self.assertIn("10.0.0.0/8", content, "Egress must block private RFC 1918")

    def test_docker_compose_mounts_data_dir(self):
        compose_path = HERMES_DIR / "docker-compose.yml"
        self.assertTrue(compose_path.exists())
        content = compose_path.read_text(encoding="utf-8")
        self.assertTrue("${JUDGE_DATA_DIR}:/opt/data/workspaces" in content or "${JUDGE_DATA_DIR:-./data}:/opt/data/workspaces" in content,
                      "docker-compose.yml must mount ${JUDGE_DATA_DIR} as /opt/data/workspaces")

    def test_soul_md_personality(self):
        soul_path = HERMES_DIR / "config" / "SOUL.md"
        self.assertTrue(soul_path.exists())
        content = soul_path.read_text(encoding="utf-8")
        self.assertIn("AI-судья", content)
        self.assertIn("no_data", content, "SOUL.md must instruct to use no_data instead of guessing")


if __name__ == "__main__":
    unittest.main()
