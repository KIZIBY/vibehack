"""T029 (часть 1): ``app.scoring`` — тонкий загрузчик ``compute_score`` из ``hermes/plugins/ai-judge/tools.py``.
Тесты написаны ДО реализации (RED).

Контракт:
- ``app.scoring.compute_score(criteria)`` — та же функция, что использует инструмент ``judge_score`` плагина
  (путь вычисляется от файла ``scoring.py``; устав I-4: итог считает один код, а не две копии);
- ``ValueError`` для невалидных входов, как у плагина;
- при отсутствии файла плагина — понятная ошибка (``FileNotFoundError`` с путём) при импорте/загрузке.

Кросс-тест: результат совпадает с ``json.loads(judge_score({...}))`` бит в бит (``total``, ``breakdown``);
ошибки: ``ValueError`` <-> ``{"success": false}``.
"""
from __future__ import annotations

import importlib.util
import json
import struct
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
TOOLS = REPO / "hermes" / "plugins" / "ai-judge" / "tools.py"


def load_plugin_tools():
    """Независимая загрузка модуля плагина — эталон для сравнения."""
    spec = importlib.util.spec_from_file_location("ai_judge_tools_reference", TOOLS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def bits(x: float) -> bytes:
    return struct.pack(">d", x)


VALID_CASES = {
    "single": [{"name": "A", "score": 7, "max_score": 10, "weight": 1}],
    "weights": [
        {"name": "Код", "score": 8, "max_score": 10, "weight": 3},
        {"name": "Бизнес", "score": 5, "max_score": 10, "weight": 1},
        {"name": "Дизайн", "score": 9, "max_score": 10, "weight": 0.5},
    ],
    "different_scales": [
        {"name": "A", "score": 3, "max_score": 5, "weight": 1},
        {"name": "B", "score": 70, "max_score": 100, "weight": 2},
        {"name": "C", "score": 1, "max_score": 3, "weight": 1},
    ],
    "boundaries_zero": [
        {"name": "A", "score": 0, "max_score": 10, "weight": 1},
        {"name": "B", "score": 0, "max_score": 7, "weight": 2},
    ],
    "boundaries_max": [
        {"name": "A", "score": 10, "max_score": 10, "weight": 1},
        {"name": "B", "score": 7, "max_score": 7, "weight": 2},
    ],
    "defaults": [{"name": "A", "score": 5}, {"name": "B", "score": 10}],
    "fractions": [
        {"name": "A", "score": 6.67, "max_score": 10, "weight": 1},
        {"name": "B", "score": 1.0 / 3.0, "max_score": 1, "weight": 7},
        {"name": "C", "score": 2.5, "max_score": 9, "weight": 0.1},
    ],
    "rounding_edge": [
        {"name": "A", "score": 1, "max_score": 3, "weight": 1},
        {"name": "B", "score": 2, "max_score": 3, "weight": 1},
        {"name": "C", "score": 1, "max_score": 3, "weight": 1},
    ],
    "unicode_names": [{"name": "Качество кода — 🚀", "score": 4, "max_score": 8, "weight": 1.5}],
}

INVALID_CASES = {
    "empty": [],
    "not_a_list": "criteria",
    "none": None,
    "no_name": [{"score": 5, "max_score": 10}],
    "blank_name": [{"name": "  ", "score": 5, "max_score": 10}],
    "duplicate_name": [{"name": "A", "score": 5}, {"name": "A", "score": 6}],
    "score_above_max": [{"name": "A", "score": 11, "max_score": 10}],
    "score_negative": [{"name": "A", "score": -1, "max_score": 10}],
    "zero_max": [{"name": "A", "score": 0, "max_score": 0}],
    "zero_weight": [{"name": "A", "score": 5, "max_score": 10, "weight": 0}],
    "negative_weight": [{"name": "A", "score": 5, "max_score": 10, "weight": -2}],
    "missing_score": [{"name": "A", "max_score": 10}],
    "bool_score": [{"name": "A", "score": True, "max_score": 10}],
    "string_score": [{"name": "A", "score": "5", "max_score": 10}],
    "nan_score": [{"name": "A", "score": float("nan"), "max_score": 10}],
    "inf_weight": [{"name": "A", "score": 5, "max_score": 10, "weight": float("inf")}],
    "item_not_object": ["A"],
}


def test_scoring_module_exposes_compute_score():
    import app.scoring as scoring

    assert callable(scoring.compute_score)


def test_tools_path_points_at_plugin_file():
    import app.scoring as scoring

    assert Path(scoring.TOOLS_PATH).resolve() == TOOLS.resolve()


@pytest.mark.parametrize("case", sorted(VALID_CASES))
def test_compute_score_equals_judge_score_bit_for_bit(case):
    import app.scoring as scoring

    criteria = VALID_CASES[case]
    plugin = load_plugin_tools()
    via_tool = json.loads(plugin.judge_score({"criteria": criteria}))
    assert via_tool["success"] is True

    mine = scoring.compute_score(criteria)

    assert bits(mine["total"]) == bits(via_tool["total"])
    assert mine["breakdown"] == via_tool["breakdown"]
    for a, b in zip(mine["breakdown"], via_tool["breakdown"]):
        for key in ("score", "max_score", "weight", "percent"):
            assert bits(a[key]) == bits(b[key])
    assert json.dumps(mine, ensure_ascii=False, sort_keys=True) == json.dumps(
        {k: v for k, v in via_tool.items() if k != "success"}, ensure_ascii=False, sort_keys=True)


@pytest.mark.parametrize("case", sorted(INVALID_CASES))
def test_invalid_input_raises_value_error_where_tool_reports_failure(case):
    import app.scoring as scoring

    criteria = INVALID_CASES[case]
    plugin = load_plugin_tools()
    via_tool = json.loads(plugin.judge_score({"criteria": criteria}))
    assert via_tool["success"] is False

    with pytest.raises(ValueError) as excinfo:
        scoring.compute_score(criteria)

    assert str(excinfo.value) == via_tool["error"]


def test_compute_score_is_deterministic():
    import app.scoring as scoring

    criteria = VALID_CASES["fractions"]
    first = scoring.compute_score(criteria)
    for _ in range(20):
        assert scoring.compute_score(criteria) == first


def test_compute_score_does_not_mutate_input():
    import copy

    import app.scoring as scoring

    criteria = copy.deepcopy(VALID_CASES["weights"])
    scoring.compute_score(criteria)

    assert criteria == VALID_CASES["weights"]


def test_known_total_value():
    import app.scoring as scoring

    # 0.8*3 + 0.5*1 + 0.9*0.5 = 3.35 ; 3.35 / 4.5 * 100 = 74.44
    assert scoring.compute_score(VALID_CASES["weights"])["total"] == 74.44


def test_loader_reports_missing_plugin_file_clearly(tmp_path):
    import app.scoring as scoring

    missing = tmp_path / "no" / "tools.py"
    with pytest.raises(FileNotFoundError) as excinfo:
        scoring.load_compute_score(missing)

    assert str(missing) in str(excinfo.value)


def test_loader_rejects_file_without_compute_score(tmp_path):
    import app.scoring as scoring

    broken = tmp_path / "tools.py"
    broken.write_text("VALUE = 1\n", encoding="utf-8")

    with pytest.raises(ImportError) as excinfo:
        scoring.load_compute_score(broken)

    assert "compute_score" in str(excinfo.value)


def test_loader_does_not_pollute_sys_modules_with_plugin_name():
    import sys

    import app.scoring  # noqa: F401

    assert "tools" not in sys.modules or getattr(sys.modules["tools"], "__file__", "") != str(TOOLS)
