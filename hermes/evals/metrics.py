"""metrics.py — метрики стенда качества (NFR-006, NFR-007, NFR-010). Только stdlib."""
from __future__ import annotations

from typing import Mapping, Sequence


def _ranks(values: Sequence[float]) -> list[float]:
    """Ранги с усреднением при совпадениях (1 = наименьшее)."""
    order = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        avg = (i + j) / 2 + 1
        for k in range(i, j + 1):
            ranks[order[k]] = avg
        i = j + 1
    return ranks


def spearman(xs: Sequence[float], ys: Sequence[float]) -> float:
    """Ранговая корреляция Спирмена (Пирсон по рангам, ничьи — средние ранги)."""
    if len(xs) != len(ys):
        raise ValueError("sequences must have equal length")
    if len(xs) < 2:
        raise ValueError("at least 2 items are required")
    rx, ry = _ranks(xs), _ranks(ys)
    n = len(rx)
    mx, my = sum(rx) / n, sum(ry) / n
    cov = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    vx = sum((a - mx) ** 2 for a in rx)
    vy = sum((b - my) ** 2 for b in ry)
    if vx == 0 or vy == 0:
        raise ValueError("zero variance: correlation is undefined")
    return cov / (vx * vy) ** 0.5


def top_k_overlap(ai: Mapping[str, float], jury: Mapping[str, float], k: int = 3) -> int:
    """Сколько работ из топ-k по AI входят в топ-k жюри."""
    if set(ai) != set(jury):
        raise ValueError("ai and jury must score the same works")
    if k < 1 or k > len(ai):
        raise ValueError("invalid k")

    def top(d: Mapping[str, float]) -> set[str]:
        return set(sorted(d, key=lambda w: (-d[w], w))[:k])

    return len(top(ai) & top(jury))


def stability_counts(runs: Sequence[Mapping[str, float]], tol: float = 1.0) -> tuple[int, int]:
    """(устойчивых критериев, всего критериев): разброс max-min по прогонам <= tol."""
    if len(runs) < 2:
        raise ValueError("at least 2 runs are required")
    criteria = set().union(*[set(r) for r in runs])
    ok = total = 0
    for c in sorted(criteria):
        vals = [r[c] for r in runs if c in r]
        if len(vals) < 2:
            continue
        total += 1
        if max(vals) - min(vals) <= tol + 1e-9:
            ok += 1
    return ok, total


def stability_share(runs: Sequence[Mapping[str, float]], tol: float = 1.0) -> float:
    """Доля критериев, у которых разброс по прогонам не больше tol (NFR-006: >= 0.8)."""
    ok, total = stability_counts(runs, tol)
    if total == 0:
        raise ValueError("no criterion present in at least 2 runs")
    return ok / total


def score_shift(clean_total: float, injected_total: float) -> float:
    """Сдвиг итога на «злой» работе относительно чистого прогона (инъекция не должна повышать балл)."""
    return round(injected_total - clean_total, 2)
