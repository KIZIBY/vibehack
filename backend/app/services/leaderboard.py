"""Таблица оценок и пояснения — чистые функции без БД (FR-021, FR-025, FR-026).

Вход — простые dataclass ниже (их собирает слой доступа к данным), выход — словари строго по схемам
``Leaderboard`` и ``Explanation`` из ``specs/001-ai-judge-platform/contracts/openapi.yaml``.

Правила:
- текущий балл критерия: ``override.score`` (правка жюри), иначе ``agent_score``; исходный балл агента
  правка не затирает (он виден в пояснении);
- итог — ``scoring.compute_score`` (устав I-4: сам итог не считается нигде, кроме плагина); в итог входят
  только критерии со значением; ``no_data``, ``human_pending`` и не оценённые критерии не входят, а работа
  с такими критериями помечается ``complete=false``;
- значение вне ``[0, max_score]`` (в том числе нечисло) не считается и не роняет таблицу: критерий
  показывается как ``no_data`` с причиной ``invalid_score``;
- ранги: по убыванию итога, равные итоги — одно место (1, 1, 3); без итога ``rank=None`` и внизу;
  ранг считается по всей таблице до фильтра и не зависит от сортировки;
- ``stale``: оценка с ``rubric_version`` меньше версии, в которой критерий изменился по смыслу
  (``changed_criteria``, передаётся входом); такая оценка в итоге остаётся, но подсвечивается.
"""
from __future__ import annotations

import math
from collections import Counter
from dataclasses import dataclass
from typing import Any, Mapping, Sequence

from app.scoring import compute_score

FLAG_TYPES = (
    "plagiarism", "pre_start_project", "claim_mismatch", "prompt_injection",
    "incomplete_materials", "agent_failure", "secret_exposed",
)
ORDERS = ("asc", "desc")
HUMAN = "human"


# ─────────────────────────────── входные структуры ───────────────────────────────

@dataclass(frozen=True)
class CriterionDef:
    id: str
    name: str
    weight: float
    max_score: float
    agent: str   # ScoringRole: code | business | design | critic-uniqueness | critic-honesty | human


@dataclass(frozen=True)
class RubricInfo:
    version: int
    criteria: Sequence[CriterionDef]


@dataclass(frozen=True)
class EvidenceItem:
    kind: str
    ref: str
    quote: str | None = None
    available: bool = True   # false: материал удалён по сроку хранения, ссылка осталась текстом


@dataclass(frozen=True)
class OverrideInfo:
    score: float
    reason: str
    at: str   # ISO 8601


@dataclass(frozen=True)
class CriterionScore:
    criterion_id: str
    status: str   # scored | no_data
    agent_score: float | None = None
    max_score: float | None = None
    rubric_version: int = 1
    justification: str = ""
    evidence: Sequence[EvidenceItem] = ()
    confidence: float | None = None
    no_data_reason: str | None = None
    override: OverrideInfo | None = None
    run_id: str | None = None
    version: int = 1   # для expected_version при правке
    # Имя критерия на момент оценки: id критерия у каждой версии рубрики свой, а между версиями критерии
    # сопоставляются по name (data-model.md, FR-007) — так оценки прошлой версии не пропадают из таблицы.
    criterion_name: str | None = None


@dataclass(frozen=True)
class FlagInfo:
    type: str
    confidence: float
    note: str
    evidence: Sequence[EvidenceItem] = ()
    criterion_id: str | None = None
    related_submission_id: str | None = None
    related_url: str | None = None


@dataclass(frozen=True)
class SubmissionScores:
    submission_id: str
    team_name: str
    scores: Sequence[CriterionScore] = ()
    flags: Sequence[FlagInfo] = ()
    cost_usd: float | None = None


# ─────────────────────────────── разбор значения критерия ───────────────────────────────

@dataclass(frozen=True)
class _Resolved:
    status: str   # scored | no_data | human_pending | not_evaluated
    score: float | None = None
    overridden: bool = False
    reason: str | None = None


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _in_scale(value: Any, max_score: float) -> bool:
    return _is_number(value) and 0 <= value <= max_score


def _resolve(criterion: CriterionDef, entry: CriterionScore | None) -> _Resolved:
    if entry is None:
        return _Resolved("human_pending" if criterion.agent == HUMAN else "not_evaluated")
    if entry.override is not None:
        if _in_scale(entry.override.score, criterion.max_score):
            return _Resolved("scored", entry.override.score, overridden=True)
        return _Resolved("no_data", reason="invalid_score")
    if entry.status == "scored":
        if _in_scale(entry.agent_score, criterion.max_score):
            return _Resolved("scored", entry.agent_score)
        return _Resolved("no_data", reason="invalid_score")
    if criterion.agent == HUMAN:
        return _Resolved("human_pending")   # критерий жюри без правки ждёт человека
    return _Resolved("no_data", reason=entry.no_data_reason)


def _entries_by_criterion(submission: SubmissionScores, criteria: Sequence[CriterionDef]) -> dict[str, CriterionScore]:
    """Оценка критерия: по id текущей версии, иначе по имени (оценки прошлых версий рубрики).

    Из нескольких кандидатов побеждает оценка более новой версии рубрики, при равенстве — более поздняя
    в списке (порядок входа — хронологический). Записи, не сопоставленные ни с каким критерием, игнорируются.
    Имя сопоставляет только если оно однозначно в текущей рубрике.
    """
    ids = {c.id for c in criteria}
    name_counts = Counter(c.name.strip() for c in criteria)
    by_name = {c.name.strip(): c.id for c in criteria if name_counts[c.name.strip()] == 1}
    best: dict[str, tuple[tuple[int, int], CriterionScore]] = {}
    for position, entry in enumerate(submission.scores):
        if entry.criterion_id in ids:
            target = entry.criterion_id
        elif entry.criterion_name is not None and entry.criterion_name.strip() in by_name:
            target = by_name[entry.criterion_name.strip()]
        else:
            continue
        rank = (entry.rubric_version, position)
        if target not in best or rank >= best[target][0]:
            best[target] = (rank, entry)
    return {target: entry for target, (_, entry) in best.items()}


# ─────────────────────────────── таблица ───────────────────────────────

def build_leaderboard(
    *,
    project_id: str,
    rubric: RubricInfo | None,
    submissions: Sequence[SubmissionScores],
    generated_at: str,
    changed_criteria: Mapping[str, int] | None = None,
    sort: str = "total",
    order: str = "desc",
    flag: str | None = None,
) -> dict:
    """Таблица оценок по схеме ``Leaderboard``. ``ValueError`` — неизвестные ``sort``/``order``/``flag``."""
    criteria = list(rubric.criteria) if rubric is not None else []
    ids = [c.id for c in criteria]
    if len(set(ids)) != len(ids):
        raise ValueError("duplicate criterion id in rubric")
    if order not in ORDERS:
        raise ValueError(f"order must be one of {ORDERS}")
    if flag is not None and flag not in FLAG_TYPES:
        raise ValueError(f"unknown flag type: {flag}")
    if sort != "total" and sort not in ids:
        raise ValueError(f"unknown sort column: {sort}")
    changed = changed_criteria or {}

    rows: list[dict] = []
    stale_ids: set[str] = set()
    for submission in submissions:
        row, row_stale = _build_row(submission, criteria, changed)
        rows.append(row)
        stale_ids.update(row_stale)

    _assign_ranks(rows)
    if flag is not None:
        rows = [r for r in rows if any(f["type"] == flag and f["count"] > 0 for f in r["flags"])]
    rows = _sorted_rows(rows, sort, order)

    costs = [s.cost_usd for s in submissions]
    cost_usd = None if any(not _is_number(c) for c in costs) else round(sum(costs), 6)

    return {
        "project_id": project_id,
        "rubric_version": rubric.version if rubric is not None else None,
        "generated_at": generated_at,
        "stale_criteria": [i for i in ids if i in stale_ids],
        "criteria": [
            {"id": c.id, "name": c.name, "weight": c.weight, "max_score": c.max_score, "agent": c.agent}
            for c in criteria
        ],
        "rows": rows,
        "cost_usd": cost_usd,
    }


def _build_row(
    submission: SubmissionScores, criteria: Sequence[CriterionDef], changed: Mapping[str, int],
) -> tuple[dict, set[str]]:
    entries = _entries_by_criterion(submission, criteria)
    cells: dict[str, dict] = {}
    inputs: list[dict] = []
    stale: set[str] = set()
    for criterion in criteria:
        entry = entries.get(criterion.id)
        resolved = _resolve(criterion, entry)
        is_stale = (
            resolved.status == "scored" and entry is not None
            and criterion.id in changed and entry.rubric_version < changed[criterion.id]
        )
        if is_stale:
            stale.add(criterion.id)
        cells[criterion.id] = {
            "status": resolved.status,
            "score": resolved.score,
            "max_score": criterion.max_score,
            "overridden": resolved.overridden,
            "stale": is_stale,
        }
        if resolved.status == "scored":
            # имя = id критерия: id уникальны, а имена в рубрике могут повторяться
            inputs.append({"name": criterion.id, "score": resolved.score,
                           "max_score": criterion.max_score, "weight": criterion.weight})

    total = compute_score(inputs)["total"] if inputs else None
    counts = Counter(f.type for f in submission.flags)
    row = {
        "submission_id": submission.submission_id,
        "team_name": submission.team_name,
        "rank": None,
        "total": total,
        "complete": bool(criteria) and len(inputs) == len(criteria),
        "cells": cells,
        "flags": [{"type": t, "count": counts[t]} for t in sorted(counts)],
    }
    return row, stale


def _assign_ranks(rows: list[dict]) -> None:
    totals = [r["total"] for r in rows if r["total"] is not None]
    for row in rows:
        if row["total"] is not None:
            row["rank"] = 1 + sum(1 for t in totals if t > row["total"])


def _sorted_rows(rows: list[dict], sort: str, order: str) -> list[dict]:
    def value(row: dict) -> float | None:
        if sort == "total":
            return row["total"]
        cell = row["cells"][sort]
        return cell["score"] if cell["status"] == "scored" else None

    by_name = sorted(rows, key=lambda r: (r["team_name"].casefold(), r["submission_id"]))
    with_value = [r for r in by_name if value(r) is not None]
    without_value = [r for r in by_name if value(r) is None]
    with_value.sort(key=value, reverse=(order == "desc"))   # sort устойчив и при reverse
    return with_value + without_value


# ─────────────────────────────── пояснение ───────────────────────────────

def build_explanation(
    *,
    criterion: CriterionDef,
    team_name: str,
    entry: CriterionScore | None,
    flags: Sequence[FlagInfo] = (),
) -> dict:
    """Пояснение оценки по схеме ``Explanation``; флаги — только относящиеся к этому критерию."""
    resolved = _resolve(criterion, entry)
    status, reason = resolved.status, resolved.reason
    if status == "not_evaluated":
        status, reason = "no_data", "not_evaluated"   # в схеме пояснения нет not_evaluated

    result: dict[str, Any] = {
        "criterion_id": criterion.id,
        "criterion_name": criterion.name,
        "team_name": team_name,
        "status": status,
        "score": resolved.score,
        "max_score": criterion.max_score,
        "agent_score": entry.agent_score if entry is not None and _is_number(entry.agent_score) else None,
        "agent": criterion.agent,
        "justification": entry.justification if entry is not None else "",
        "evidence": [_evidence(e) for e in entry.evidence] if entry is not None else [],
        "flags": [_flag(f) for f in flags if f.criterion_id == criterion.id],
        "override": None,
        "version": entry.version if entry is not None else 0,
    }
    if status == "no_data":
        reason = reason or (entry.no_data_reason if entry is not None else None)
        if reason:
            result["no_data_reason"] = reason
    if entry is not None:
        if _is_number(entry.confidence):
            result["confidence"] = entry.confidence
        if entry.run_id is not None:
            result["run_id"] = entry.run_id
        if entry.override is not None:
            result["override"] = {"score": entry.override.score, "reason": entry.override.reason,
                                  "at": entry.override.at}
    return result


def _evidence(item: EvidenceItem) -> dict:
    result = {"kind": item.kind, "ref": item.ref}
    if item.quote is not None:
        result["quote"] = item.quote
    result["available"] = item.available
    return result


def _flag(item: FlagInfo) -> dict:
    result: dict[str, Any] = {
        "type": item.type,
        "confidence": item.confidence,
        "note": item.note,
        "evidence": [_evidence(e) for e in item.evidence],
    }
    for key in ("criterion_id", "related_submission_id", "related_url"):
        if getattr(item, key) is not None:
            result[key] = getattr(item, key)
    return result
