"""Обработчики инструментов ai-judge. Только stdlib: модуль тестируется без Hermes."""
import json
import math

DEFAULT_MAX_SCORE = 10.0
DEFAULT_WEIGHT = 1.0


def _number(item, key, default=None):
    value = item.get(key, default)
    if value is None:
        raise ValueError(f"criterion '{item.get('name')}': '{key}' is required")
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"criterion '{item.get('name')}': '{key}' must be a finite number")
    return float(value)


def compute_score(criteria):
    """Итог по рубрике: каждая оценка нормируется на свой максимум, взвешивается и приводится к 0–100.

    ValueError — пустая рубрика, критерий без имени или повтор имени, оценка вне [0, max_score],
    неположительные max_score или weight.
    """
    if not isinstance(criteria, list) or not criteria:
        raise ValueError("criteria must be a non-empty list")

    seen = set()
    breakdown = []
    weighted_sum = 0.0
    total_weight = 0.0
    for item in criteria:
        if not isinstance(item, dict):
            raise ValueError("each criterion must be an object")
        name = str(item.get("name") or "").strip()
        if not name:
            raise ValueError("criterion without name")
        if name in seen:
            raise ValueError(f"duplicate criterion: {name}")
        seen.add(name)

        score = _number(item, "score")
        max_score = _number(item, "max_score", DEFAULT_MAX_SCORE)
        weight = _number(item, "weight", DEFAULT_WEIGHT)
        if max_score <= 0:
            raise ValueError(f"criterion '{name}': max_score must be > 0")
        if weight <= 0:
            raise ValueError(f"criterion '{name}': weight must be > 0")
        if not 0 <= score <= max_score:
            raise ValueError(f"criterion '{name}': score {score:g} is outside [0, {max_score:g}]")

        ratio = score / max_score
        weighted_sum += ratio * weight
        total_weight += weight
        breakdown.append({
            "name": name,
            "score": score,
            "max_score": max_score,
            "weight": weight,
            "percent": round(ratio * 100, 2),
        })

    return {"total": round(weighted_sum / total_weight * 100, 2), "breakdown": breakdown}


def judge_score(params, **kwargs):
    del kwargs
    try:
        result = compute_score((params or {}).get("criteria"))
    except ValueError as exc:
        return json.dumps({"success": False, "error": str(exc)}, ensure_ascii=False)
    return json.dumps({"success": True, **result}, ensure_ascii=False)
