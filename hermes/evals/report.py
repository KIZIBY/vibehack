"""report.py — стенд оценки качества: Спирмен, совпадение топ-3, стабильность по 3 прогонам, сдвиг на злых работах.

Офлайн: читает фикстуру прогонов (hermes/evals/fixtures/gold.json), живой Hermes не нужен.
Итоги считаются детерминированно через compute_score плагина (не языковой моделью).
Запуск: python3 hermes/evals/report.py [путь к gold.json]
"""
from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "plugins" / "ai-judge"))

import metrics  # noqa: E402
from tools import compute_score  # noqa: E402

THRESHOLDS = {"spearman": 0.6, "top3": 2, "stability": 0.8}
DEFAULT_GOLD = HERE / "fixtures" / "gold.json"


def _total(rubric, scores):
    crit = [{"name": c["id"], "score": scores[c["id"]], "max_score": c.get("max_score", 10),
             "weight": c.get("weight", 1)} for c in rubric if c["id"] in scores]
    return compute_score(crit)["total"]


def evaluate(path=DEFAULT_GOLD):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    rubric = data["rubric"]
    jury = data["jury"]
    per_work, ai_totals = {}, {}
    ok = total = 0
    for work, runs in data["ai_runs"].items():
        totals = [_total(rubric, r) for r in runs]
        ai_totals[work] = round(statistics.fmean(totals), 2)
        o, t = metrics.stability_counts(runs, tol=1.0)
        ok, total = ok + o, total + t
        per_work[work] = {"ai_total": ai_totals[work], "jury_total": jury.get(work),
                          "run_totals": totals, "stable": f"{o}/{t}"}
    works = sorted(ai_totals)
    rho = metrics.spearman([ai_totals[w] for w in works], [jury[w] for w in works])
    overlap = metrics.top_k_overlap(ai_totals, {w: jury[w] for w in works}, 3)
    stability = ok / total if total else 0.0
    evil_shift = {}
    for work, pair in (data.get("evil_runs") or {}).items():
        evil_shift[work] = metrics.score_shift(_total(rubric, pair["clean"]), _total(rubric, pair["injected"]))
    result = {
        "synthetic": bool(data.get("synthetic")),
        "works": len(works),
        "spearman": round(rho, 4),
        "top3": {"overlap": overlap, "of": 3},
        "stability": round(stability, 4),
        "per_work": per_work,
        "evil_shift": evil_shift,
    }
    result["passed"] = {
        "spearman": rho >= THRESHOLDS["spearman"],
        "top3": overlap >= THRESHOLDS["top3"],
        "stability": stability >= THRESHOLDS["stability"],
    }
    return result


def render_markdown(res):
    mark = lambda ok: "да" if ok else "НЕТ"  # noqa: E731
    lines = []
    if res["synthetic"]:
        lines.append("> Данные synthetic (фикстура стенда): цифры подтверждают работу расчёта, не качество моделей.")
        lines.append("")
    lines += [
        "| Метрика | Значение | Порог | Выполнено |",
        "|---|---|---|---|",
        f"| Корреляция Спирмена AI и жюри | {res['spearman']} | >= {THRESHOLDS['spearman']} | {mark(res['passed']['spearman'])} |",
        f"| Совпадение топ-3 | {res['top3']['overlap']} из 3 | >= {THRESHOLDS['top3']} | {mark(res['passed']['top3'])} |",
        f"| Стабильность (разброс <= 1 в 3 прогонах) | {res['stability']} | >= {THRESHOLDS['stability']} | {mark(res['passed']['stability'])} |",
        "",
        "| Работа | AI (среднее 3 прогонов) | Жюри | Стабильных критериев |",
        "|---|---|---|---|",
    ]
    for w, r in sorted(res["per_work"].items()):
        lines.append(f"| {w} | {r['ai_total']} | {r['jury_total']} | {r['stable']} |")
    if res["evil_shift"]:
        lines += ["", "| Злая работа | Сдвиг итога (инъекция минус чистый прогон) |", "|---|---|"]
        for w, d in sorted(res["evil_shift"].items()):
            lines.append(f"| {w} | {d:+} |")
    return "\n".join(lines) + "\n"


def main(argv):
    path = Path(argv[1]) if len(argv) > 1 else DEFAULT_GOLD
    res = evaluate(path)
    sys.stdout.write(render_markdown(res))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
