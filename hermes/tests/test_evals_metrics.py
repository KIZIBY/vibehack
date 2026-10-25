"""T071: стенд оценки качества — метрики и отчёт (офлайн, на фикстурах)."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERMES_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERMES_DIR / "evals"))
sys.path.insert(0, str(HERMES_DIR / "plugins" / "ai-judge"))
import metrics  # noqa: E402
import report  # noqa: E402

GOLD = HERMES_DIR / "evals" / "fixtures" / "gold.json"


class MetricsTest(unittest.TestCase):
    def test_spearman_basic(self):
        self.assertAlmostEqual(metrics.spearman([1, 2, 3, 4], [10, 20, 30, 40]), 1.0)
        self.assertAlmostEqual(metrics.spearman([1, 2, 3, 4], [4, 3, 2, 1]), -1.0)

    def test_spearman_ties_average_ranks(self):
        # ранги x: 1, 2.5, 2.5, 4; y: 1,2,3,4 -> известное значение 0.948683...
        self.assertAlmostEqual(metrics.spearman([1, 2, 2, 3], [1, 2, 3, 4]), 0.9486832981, places=6)

    def test_spearman_errors(self):
        with self.assertRaises(ValueError):
            metrics.spearman([1, 2], [1])
        with self.assertRaises(ValueError):
            metrics.spearman([1], [1])
        with self.assertRaises(ValueError):
            metrics.spearman([5, 5, 5], [1, 2, 3])  # нулевая дисперсия

    def test_top_k_overlap(self):
        ai = {"a": 90, "b": 80, "c": 70, "d": 60}
        jury = {"a": 50, "b": 95, "c": 40, "d": 85}
        self.assertEqual(metrics.top_k_overlap(ai, jury, 3), 2)  # {a,b,c} vs {b,d,a}
        with self.assertRaises(ValueError):
            metrics.top_k_overlap(ai, {"a": 1}, 3)

    def test_stability_share(self):
        runs = [{"c1": 5, "c2": 5, "c3": 5}, {"c1": 6, "c2": 8, "c3": 5}, {"c1": 5.5, "c2": 5, "c3": 5}]
        # разброс: c1=1 (ok), c2=3 (нет), c3=0 (ok) -> 2/3
        self.assertAlmostEqual(metrics.stability_share(runs, tol=1.0), 2 / 3)
        with self.assertRaises(ValueError):
            metrics.stability_share([{"c1": 1}], tol=1.0)  # нужно ≥ 2 прогонов

    def test_stability_ignores_criteria_missing_in_some_runs(self):
        runs = [{"c1": 5}, {"c1": 5, "c2": 1}, {"c1": 5}]
        self.assertAlmostEqual(metrics.stability_share(runs), 1.0)

    def test_score_shift(self):
        self.assertEqual(metrics.score_shift(60.0, 95.5), 35.5)


class ReportTest(unittest.TestCase):
    def test_gold_fixture_shape(self):
        data = json.loads(GOLD.read_text(encoding="utf-8"))
        self.assertTrue(data.get("synthetic"), "фикстура должна быть помечена synthetic")
        self.assertGreaterEqual(len(data["jury"]), 10)
        for work, runs in data["ai_runs"].items():
            self.assertEqual(len(runs), 3, work)

    def test_evaluate_gold(self):
        res = report.evaluate(GOLD)
        for key in ("spearman", "top3", "stability", "per_work", "passed"):
            self.assertIn(key, res)
        self.assertEqual(res["top3"]["of"], 3)
        self.assertEqual(set(res["passed"]), {"spearman", "top3", "stability"})
        self.assertGreaterEqual(res["spearman"], -1.0)
        self.assertLessEqual(res["spearman"], 1.0)

    def test_evaluate_uses_deterministic_totals(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "g.json"
            p.write_text(json.dumps({
                "synthetic": True,
                "rubric": [{"id": "c1", "max_score": 10, "weight": 1}, {"id": "c2", "max_score": 10, "weight": 3}],
                "jury": {"w1": 40.0, "w2": 70.0, "w3": 90.0},
                "ai_runs": {w: [{"c1": s1, "c2": s2}] * 3 for w, (s1, s2) in
                            {"w1": (4, 4), "w2": (7, 7), "w3": (9, 9)}.items()},
            }), encoding="utf-8")
            res = report.evaluate(p)
            self.assertAlmostEqual(res["spearman"], 1.0)
            self.assertEqual(res["top3"]["overlap"], 3)
            self.assertAlmostEqual(res["stability"], 1.0)
            self.assertEqual(res["per_work"]["w2"]["ai_total"], 70.0)
            self.assertTrue(all(res["passed"].values()))

    def test_thresholds_from_spec(self):
        self.assertEqual(report.THRESHOLDS, {"spearman": 0.6, "top3": 2, "stability": 0.8})

    def test_markdown_table(self):
        md = report.render_markdown(report.evaluate(GOLD))
        for needle in ("Спирмен", "топ-3", "стабильность", "|", "synthetic"):
            self.assertIn(needle.lower(), md.lower())

    def test_evil_shift_in_report(self):
        res = report.evaluate(GOLD)
        self.assertIn("evil_shift", res)
        self.assertIsInstance(res["evil_shift"], dict)

    def test_cli(self):
        proc = subprocess.run([sys.executable, str(HERMES_DIR / "evals" / "report.py"), str(GOLD)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("Спирмен", proc.stdout)
        self.assertNotIn("/Users/", proc.stdout)


if __name__ == "__main__":
    unittest.main()
