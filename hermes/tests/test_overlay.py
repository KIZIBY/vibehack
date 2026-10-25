"""Unit-тесты обвеса Hermes: инструмент judge_score и слияние config.yaml. Без зависимостей.

Запуск: python3 -m unittest discover -s hermes/tests
"""
import copy
import importlib.util
import json
import unittest
from pathlib import Path

HERMES_DIR = Path(__file__).resolve().parent.parent


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tools = _load("ai_judge_tools", HERMES_DIR / "plugins" / "ai-judge" / "tools.py")
overlay = _load("apply_overlay", HERMES_DIR / "scripts" / "apply_overlay.py")


class ComputeScoreTest(unittest.TestCase):
    def test_weighted_total_normalised_to_100(self):
        result = tools.compute_score([
            {"name": "Идея", "score": 10, "weight": 1},
            {"name": "Код", "score": 5, "weight": 3},
        ])
        # (1.0*1 + 0.5*3) / 4 = 0.625
        self.assertEqual(result["total"], 62.5)
        self.assertEqual([c["percent"] for c in result["breakdown"]], [100.0, 50.0])

    def test_defaults_max_10_weight_1(self):
        result = tools.compute_score([{"name": "A", "score": 7}])
        self.assertEqual(result["total"], 70.0)
        self.assertEqual(result["breakdown"][0]["max_score"], 10.0)
        self.assertEqual(result["breakdown"][0]["weight"], 1.0)

    def test_custom_max_score(self):
        self.assertEqual(tools.compute_score([{"name": "A", "score": 3, "max_score": 5}])["total"], 60.0)

    def test_rejects_invalid_input(self):
        cases = {
            "empty": [],
            "not a list": "Идея: 10",
            "no name": [{"score": 1}],
            "duplicate": [{"name": "A", "score": 1}, {"name": "A", "score": 2}],
            "missing score": [{"name": "A"}],
            "score above max": [{"name": "A", "score": 11}],
            "negative score": [{"name": "A", "score": -1}],
            "zero weight": [{"name": "A", "score": 1, "weight": 0}],
            "zero max": [{"name": "A", "score": 0, "max_score": 0}],
            "string score": [{"name": "A", "score": "9"}],
            "bool score": [{"name": "A", "score": True}],
            "nan score": [{"name": "A", "score": float("nan")}],
            "inf weight": [{"name": "A", "score": 1, "weight": float("inf")}],
        }
        for label, criteria in cases.items():
            with self.subTest(label), self.assertRaises(ValueError):
                tools.compute_score(criteria)


class JudgeScoreHandlerTest(unittest.TestCase):
    def test_success_envelope(self):
        payload = json.loads(tools.judge_score({"criteria": [{"name": "A", "score": 8}]}, task_id="t"))
        self.assertTrue(payload["success"])
        self.assertEqual(payload["total"], 80.0)

    def test_error_envelope_instead_of_exception(self):
        for params in ({"criteria": []}, {}, None):
            with self.subTest(params=params):
                payload = json.loads(tools.judge_score(params))
                self.assertFalse(payload["success"])
                self.assertIn("criteria", payload["error"])


class MergeTest(unittest.TestCase):
    def test_keeps_server_keys_and_adds_ours(self):
        server = {"model": {"provider": "anthropic", "default": "x"}, "plugins": {"enabled": ["other"]}}
        ours = {"plugins": {"enabled": ["ai-judge"]}, "approvals": {"mode": "manual"}}
        self.assertEqual(overlay.merge(server, ours), {
            "model": {"provider": "anthropic", "default": "x"},
            "plugins": {"enabled": ["other", "ai-judge"]},
            "approvals": {"mode": "manual"},
        })

    def test_lists_union_without_duplicates(self):
        self.assertEqual(overlay.merge(["a", "b"], ["b", "c"]), ["a", "b", "c"])

    def test_our_scalar_wins(self):
        self.assertEqual(overlay.merge({"approvals": {"mode": "auto"}}, {"approvals": {"mode": "manual"}}),
                         {"approvals": {"mode": "manual"}})

    def test_idempotent(self):
        ours = {"plugins": {"enabled": ["ai-judge"]}}
        once = overlay.merge({"plugins": {"enabled": ["x"]}}, copy.deepcopy(ours))
        self.assertEqual(overlay.merge(copy.deepcopy(once), copy.deepcopy(ours)), once)

    def test_empty_server_config_takes_ours(self):
        self.assertEqual(overlay.merge({}, {"plugins": {"enabled": ["ai-judge"]}}),
                         {"plugins": {"enabled": ["ai-judge"]}})


if __name__ == "__main__":
    unittest.main()
