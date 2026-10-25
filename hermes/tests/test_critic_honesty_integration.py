"""test_critic_honesty_integration.py — RED тесты полного цикла critic-honesty (T068 hardening).

Проверяет:
1. save_claims валидирует source_ref (kind + ref) для каждого утверждения.
2. Вердикт contradicted без evidence → ошибка.
3. Полный цикл: claims → scores → flag claim_mismatch → отчёт содержит всё.
4. Severity обязательна для флага claim_mismatch.
5. Максимум 20 claims (protection against abuse).
6. claim_id уникальность внутри одного вызова.
"""
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

# Добавляем корень проекта для импортов
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "hermes" / "plugins" / "ai-judge"))

import reports
import tools
from reports import save_claims, save_flag, save_scores, write_atomic


class TestCriticHonestyClaimsValidation(unittest.TestCase):
    """Валидация claims для роли critic-honesty."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="hermes_test_honesty_")
        reports.DATA_DIR = Path(self.tmpdir)
        self.run_id = "run-honesty-001"
        self.session_id = "role:critic-honesty:run-honesty-001"

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_claim_requires_source_ref(self):
        """Claim без source_ref должен отклоняться: нужно указать откуда утверждение."""
        params = {
            "run_id": self.run_id,
            "claims": [
                {
                    "claim_id": "C1",
                    "text": "Мы реализовали ML-модель",
                    "verdict": "not_found",
                    # source_ref отсутствует — должно вызвать ошибку
                    "evidence": [],
                }
            ],
        }
        with self.assertRaises(ValueError) as ctx:
            save_claims(params, session_id=self.session_id)
        self.assertIn("source_ref", str(ctx.exception).lower())

    def test_claim_source_ref_must_have_kind_and_ref(self):
        """source_ref должен содержать kind (slide/video) и ref."""
        params = {
            "run_id": self.run_id,
            "claims": [
                {
                    "claim_id": "C1",
                    "text": "Реализован биллинг",
                    "verdict": "confirmed",
                    "source_ref": {"kind": "slide"},  # ref отсутствует
                    "evidence": [{"kind": "file", "ref": "billing.py#L10"}],
                }
            ],
        }
        with self.assertRaises(ValueError) as ctx:
            save_claims(params, session_id=self.session_id)
        self.assertIn("ref", str(ctx.exception).lower())

    def test_contradicted_verdict_requires_evidence(self):
        """Вердикт contradicted без evidence должен быть отклонён — нужно доказательство расхождения."""
        params = {
            "run_id": self.run_id,
            "claims": [
                {
                    "claim_id": "C1",
                    "text": "Используется PyTorch для рекомендаций",
                    "verdict": "contradicted",
                    "source_ref": {"kind": "slide", "ref": "deck.pdf#3"},
                    "evidence": [],  # Пусто — нельзя для contradicted
                }
            ],
        }
        with self.assertRaises(ValueError) as ctx:
            save_claims(params, session_id=self.session_id)
        self.assertIn("evidence", str(ctx.exception).lower())

    def test_duplicate_claim_ids_rejected(self):
        """Повторяющиеся claim_id в одном вызове должны отклоняться."""
        params = {
            "run_id": self.run_id,
            "claims": [
                {
                    "claim_id": "C1",
                    "text": "Фича A",
                    "verdict": "confirmed",
                    "source_ref": {"kind": "slide", "ref": "deck.pdf#1"},
                    "evidence": [{"kind": "file", "ref": "a.py#L1"}],
                },
                {
                    "claim_id": "C1",  # Дубликат!
                    "text": "Фича B",
                    "verdict": "not_found",
                    "source_ref": {"kind": "slide", "ref": "deck.pdf#2"},
                    "evidence": [],
                },
            ],
        }
        with self.assertRaises(ValueError) as ctx:
            save_claims(params, session_id=self.session_id)
        self.assertIn("duplicate", str(ctx.exception).lower())

    def test_max_claims_limit(self):
        """Более 20 claims — защита от злоупотреблений."""
        claims = []
        for i in range(21):
            claims.append({
                "claim_id": f"C{i}",
                "text": f"Claim {i}",
                "verdict": "confirmed",
                "source_ref": {"kind": "slide", "ref": f"deck.pdf#{i}"},
                "evidence": [{"kind": "file", "ref": f"file{i}.py#L1"}],
            })
        params = {"run_id": self.run_id, "claims": claims}
        with self.assertRaises(ValueError) as ctx:
            save_claims(params, session_id=self.session_id)
        self.assertIn("20", str(ctx.exception))


class TestCriticHonestyFullCycle(unittest.TestCase):
    """Полный цикл: claims → scores → flag → проверка отчёта."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="hermes_test_honesty_cycle_")
        reports.DATA_DIR = Path(self.tmpdir)
        self.run_id = "run-honesty-cycle-001"
        self.session_id = "role:critic-honesty:run-honesty-cycle-001"

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_full_critic_honesty_pipeline(self):
        """Полный пайплайн critic-honesty: claims → scores → flag → итоговый отчёт."""
        # 1. Сохраняем claims
        claims_result = save_claims({
            "run_id": self.run_id,
            "claims": [
                {
                    "claim_id": "C1",
                    "text": "Реализован ML-рекомендатор на PyTorch",
                    "verdict": "contradicted",
                    "source_ref": {"kind": "slide", "ref": "deck.pdf#4"},
                    "evidence": [
                        {"kind": "file", "ref": "recommend.py#L12-L20"},
                        {"kind": "search", "ref": "grep 'import torch' — not found"},
                    ],
                },
                {
                    "claim_id": "C2",
                    "text": "REST API с аутентификацией",
                    "verdict": "confirmed",
                    "source_ref": {"kind": "slide", "ref": "deck.pdf#6"},
                    "evidence": [{"kind": "file", "ref": "auth/middleware.py#L1-L30"}],
                },
                {
                    "claim_id": "C3",
                    "text": "Адаптивный дизайн до 390px",
                    "verdict": "not_found",
                    "source_ref": {"kind": "video", "ref": "pitch.mp4#00:02:15"},
                    "evidence": [],
                },
            ],
        }, session_id=self.session_id)
        self.assertTrue(claims_result["success"])
        self.assertEqual(claims_result["claims_count"], 3)

        # 2. Сохраняем scores
        scores_result = save_scores({
            "run_id": self.run_id,
            "role": "critic-honesty",
            "scores": [
                {
                    "criterion_id": "honesty",
                    "status": "scored",
                    "score": 3,
                    "max_score": 10,
                    "confidence": 0.85,
                    "justification": "1 из 3 утверждений подтверждено, 1 опровергнуто",
                    "evidence": [
                        {"kind": "claim", "ref": "C1:contradicted"},
                        {"kind": "claim", "ref": "C2:confirmed"},
                    ],
                }
            ],
        }, session_id=self.session_id)
        self.assertTrue(scores_result["success"])

        # 3. Ставим флаг claim_mismatch
        flag_result = save_flag({
            "run_id": self.run_id,
            "role": "critic-honesty",
            "flag": {
                "type": "claim_mismatch",
                "severity": "critical",
                "confidence": 0.9,
                "note": "Заявленная ML-модель на PyTorch — в коде random.choice",
                "evidence": [
                    {"kind": "file", "ref": "recommend.py#L12"},
                    {"kind": "slide", "ref": "deck.pdf#4"},
                ],
            },
        }, session_id=self.session_id)
        self.assertTrue(flag_result["success"])

        # 4. Проверяем итоговый отчёт
        report_path = Path(self.tmpdir) / "runs" / self.run_id / "reports" / "critic-honesty.json"
        self.assertTrue(report_path.exists(), "Report file must exist after full cycle")

        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(report["kind"], "scores")
        self.assertEqual(report["role"], "critic-honesty")

        # claims сохранены
        self.assertIn("claims", report)
        self.assertEqual(len(report["claims"]), 3)
        verdicts = {c["claim_id"]: c["verdict"] for c in report["claims"]}
        self.assertEqual(verdicts["C1"], "contradicted")
        self.assertEqual(verdicts["C2"], "confirmed")
        self.assertEqual(verdicts["C3"], "not_found")

        # source_ref сохранён для каждого claim
        for claim in report["claims"]:
            self.assertIn("source_ref", claim, f"Claim {claim['claim_id']} must have source_ref")
            self.assertIn("kind", claim["source_ref"])
            self.assertIn("ref", claim["source_ref"])

        # scores сохранены
        self.assertEqual(len(report["scores"]), 1)
        self.assertEqual(report["scores"][0]["criterion_id"], "honesty")
        self.assertEqual(report["scores"][0]["score"], 3)

        # flags сохранены
        self.assertIn("flags", report)
        self.assertGreaterEqual(len(report["flags"]), 1)
        flag = report["flags"][0]
        self.assertEqual(flag["type"], "claim_mismatch")
        self.assertEqual(flag["severity"], "critical")

    def test_claim_mismatch_flag_requires_severity(self):
        """Флаг claim_mismatch должен содержать поле severity."""
        params = {
            "run_id": self.run_id,
            "role": "critic-honesty",
            "flag": {
                "type": "claim_mismatch",
                # severity отсутствует
                "confidence": 0.8,
                "note": "Расхождение обнаружено",
                "evidence": [{"kind": "slide", "ref": "deck.pdf#1"}],
            },
        }
        with self.assertRaises(ValueError) as ctx:
            save_flag(params, session_id=self.session_id)
        self.assertIn("severity", str(ctx.exception).lower())


class TestCriticHonestyToolWrapper(unittest.TestCase):
    """Тест обёрток tools.py для report_claims."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="hermes_test_honesty_tool_")
        reports.DATA_DIR = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_report_claims_tool_returns_error_json_on_invalid(self):
        """report_claims возвращает JSON с success=false при невалидных данных."""
        result = json.loads(tools.report_claims(
            {"run_id": "r1", "claims": "not-a-list"},
            session_id="role:critic-honesty:r1",
        ))
        self.assertFalse(result["success"])
        self.assertIn("error", result)

    def test_report_claims_tool_success(self):
        """report_claims возвращает success при валидных данных."""
        result = json.loads(tools.report_claims(
            {
                "run_id": "r2",
                "claims": [
                    {
                        "claim_id": "X1",
                        "text": "Feature exists",
                        "verdict": "confirmed",
                        "source_ref": {"kind": "slide", "ref": "deck.pdf#1"},
                        "evidence": [{"kind": "file", "ref": "app.py#L1"}],
                    }
                ],
            },
            session_id="role:critic-honesty:r2",
        ))
        self.assertTrue(result["success"])
        self.assertEqual(result["claims_count"], 1)


if __name__ == "__main__":
    unittest.main()
