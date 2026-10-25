"""Чтение результатов из БД: входы для ``services.leaderboard`` (таблица оценок и пояснение балла, T029/T034).

Правила выборки (``data-model.md``, «Вычисляемое»):
- рубрика = версия ``project.rubric_confirmed_version``; нет подтверждённой — таблица пустая, ``rubric_version: null``;
- работы — неудалённые работы проекта;
- текущая оценка критерия = последняя запись ``criterion_score`` по ``(created_at, id)`` среди записей, критерий которых
  сопоставлен с критерием подтверждённой версии: по id или по названию без учёта регистра (id критерия у каждой версии
  рубрики свой); правка = последняя запись ``score_override`` ЭТОЙ записи оценки, ``version`` = число правок;
- флаги — флаги последней завершённой задачи на пару (работа, роль): повторный прогон не накапливает дубли;
- ``stale_criteria`` — через ``changed_criteria`` по версии самой старой используемой оценки;
- ``cost_usd`` — сумма ``run_task.cost_usd`` проекта (в том числе задач уровня проекта) или ``None``.

Функции только читают и не делают commit. Битые данные не роняют чтение: невалидный JSON доказательств даёт пустой
список и запись WARNING в лог.
"""
from __future__ import annotations

import json
import logging
import math
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import text
from sqlalchemy.orm import Session

from ..common import utc_now_iso
from .leaderboard import (
    FLAG_TYPES, CriterionDef, CriterionScore, EvidenceItem, FlagInfo, OverrideInfo, RubricInfo, SubmissionScores,
    build_explanation, build_leaderboard,
)
from .rubric import ProjectNotFound, changed_criteria

log = logging.getLogger(__name__)

EVIDENCE_KINDS = ("file", "slide", "video", "screenshot", "url", "claim", "commit", "search")
FINISHED_STATES = ("done", "failed", "no_data")


class ResultNotFound(LookupError):
    """Нет работы или критерия подтверждённой рубрики (404)."""


@dataclass
class CurrentScore:
    """Текущая запись оценки критерия и то, что к ней привязано."""
    record_id: str
    entry: CriterionScore


@dataclass
class _Data:
    project_id: str
    confirmed_version: int | None
    rubric: RubricInfo | None
    submissions: list[SubmissionScores]
    current: dict[tuple[str, str], CurrentScore] = field(default_factory=dict)
    changed: dict[str, int] = field(default_factory=dict)
    cost_usd: float | None = None


# ─────────────────────────────── разбор значений ───────────────────────────────

def _iso(value: Any) -> str:
    """Время из БД -> ISO 8601 с часовым поясом (naive считается UTC)."""
    if isinstance(value, datetime):
        parsed = value
    else:
        try:
            parsed = datetime.fromisoformat(str(value))
        except ValueError:
            return str(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.isoformat()


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    return number if math.isfinite(number) else None


def _evidence(raw: Any, where: str) -> tuple[EvidenceItem, ...]:
    """JSON-колонка ``evidence`` -> доказательства. Мусор даёт пустой список/пропуск элемента и WARNING."""
    if raw is None:
        return ()
    data = raw
    if isinstance(raw, (str, bytes)):
        try:
            data = json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            log.warning("results: evidence не JSON (%s), доказательства пропущены", where)
            return ()
    if not isinstance(data, list):
        log.warning("results: evidence не список (%s), доказательства пропущены", where)
        return ()
    items: list[EvidenceItem] = []
    for item in data:
        if (isinstance(item, dict) and item.get("kind") in EVIDENCE_KINDS and isinstance(item.get("ref"), str)):
            quote = item.get("quote")
            items.append(EvidenceItem(kind=item["kind"], ref=item["ref"],
                                      quote=quote if isinstance(quote, str) else None))
        else:
            log.warning("results: элемент evidence некорректен (%s), пропущен", where)
    return tuple(items)


# ─────────────────────────────── загрузка ───────────────────────────────

def _load(session: Session, project_id: str, submission_id: str | None = None) -> _Data:
    project = session.execute(
        text("SELECT id, rubric_confirmed_version FROM project WHERE id = :id AND deleted_at IS NULL"),
        {"id": project_id}).mappings().first()
    if project is None:
        raise ProjectNotFound(project_id)
    confirmed = project["rubric_confirmed_version"]

    rubric = _load_rubric(session, project_id, confirmed)
    only = " AND s.id = :sub" if submission_id is not None else ""
    params: dict[str, Any] = {"p": project_id}
    if submission_id is not None:
        params["sub"] = submission_id
    submissions = session.execute(
        text(f"SELECT s.id, s.team_name FROM submission s WHERE s.project_id = :p AND s.deleted_at IS NULL{only} "
             "ORDER BY s.created_at, s.id"), params).mappings().all()

    data = _Data(project_id, confirmed, rubric, [])
    data.cost_usd = _project_cost(session, project_id)
    criteria = list(rubric.criteria) if rubric is not None else []
    flags = _load_flags(session, project_id, params, only, criteria) if submissions else {}
    scores: dict[str, dict[str, CurrentScore]] = {}
    if criteria and submissions:
        scores = _load_scores(session, project_id, params, only, criteria)
    for row in submissions:
        current = scores.get(row["id"], {})
        for cid, item in current.items():
            data.current[(row["id"], cid)] = item
        data.submissions.append(SubmissionScores(
            submission_id=row["id"], team_name=row["team_name"],
            scores=tuple(item.entry for item in current.values()),
            flags=tuple(flags.get(row["id"], ())), cost_usd=None))

    if criteria and data.current:
        oldest = min(item.entry.rubric_version for item in data.current.values())
        if confirmed is not None and oldest < confirmed:
            names = {name.casefold().strip() for name in changed_criteria(session, project_id, oldest, confirmed)}
            data.changed = {c.id: int(confirmed) for c in criteria if c.name.casefold().strip() in names}
    return data


def _load_rubric(session: Session, project_id: str, confirmed: int | None) -> RubricInfo | None:
    if confirmed is None:
        return None
    rows = session.execute(
        text("SELECT c.id, c.name, c.weight, c.max_score, c.agent FROM criterion c JOIN rubric r ON r.id = c.rubric_id "
             "WHERE r.project_id = :p AND r.version = :v ORDER BY c.position, c.id"),
        {"p": project_id, "v": confirmed}).mappings().all()
    return RubricInfo(version=int(confirmed), criteria=tuple(
        CriterionDef(id=r["id"], name=r["name"], weight=float(r["weight"]), max_score=float(r["max_score"]),
                     agent=r["agent"]) for r in rows))


def _project_cost(session: Session, project_id: str) -> float | None:
    value = session.execute(
        text("SELECT SUM(rt.cost_usd) FROM run_task rt JOIN run r ON r.id = rt.run_id WHERE r.project_id = :p"),
        {"p": project_id}).scalar()
    number = _number(value)
    return None if number is None else round(number, 6)


def _id_mapper(session: Session, project_id: str, criteria: list[CriterionDef]):
    """criterion_id любой версии рубрики -> id критерия подтверждённой версии (по id, иначе по названию)."""
    current_ids = {c.id for c in criteria}
    names: dict[str, list[str]] = {}
    for c in criteria:
        names.setdefault(c.name.casefold().strip(), []).append(c.id)
    by_name = {name: ids[0] for name, ids in names.items() if len(ids) == 1}
    all_names = {r["id"]: r["name"] for r in session.execute(
        text("SELECT c.id, c.name FROM criterion c JOIN rubric r ON r.id = c.rubric_id WHERE r.project_id = :p"),
        {"p": project_id}).mappings().all()}

    def mapper(criterion_id: str | None) -> str | None:
        if criterion_id is None:
            return None
        if criterion_id in current_ids:
            return criterion_id
        name = all_names.get(criterion_id)
        return by_name.get(name.casefold().strip()) if name is not None else None

    return mapper


def _load_scores(session: Session, project_id: str, params: dict, only: str,
                 criteria: list[CriterionDef]) -> dict[str, dict[str, CurrentScore]]:
    mapper = _id_mapper(session, project_id, criteria)
    names = {c.id: c.name for c in criteria}
    rows = session.execute(
        text("SELECT cs.id, cs.submission_id, cs.criterion_id, cs.rubric_version, cs.status, cs.score, cs.max_score, "
             "cs.justification, cs.evidence, cs.confidence, cs.no_data_reason, rt.run_id "
             "FROM criterion_score cs JOIN run_task rt ON rt.id = cs.run_task_id "
             "JOIN submission s ON s.id = cs.submission_id "
             f"WHERE s.project_id = :p AND s.deleted_at IS NULL{only} ORDER BY cs.created_at, cs.id"),
        params).mappings().all()
    latest: dict[tuple[str, str], Any] = {}
    for row in rows:   # по возрастанию (created_at, id): последняя запись перекрывает прежние
        target = mapper(row["criterion_id"])
        if target is not None:
            latest[(row["submission_id"], target)] = row
    overrides = _load_overrides(session, params, only, {row["id"] for row in latest.values()})
    result: dict[str, dict[str, CurrentScore]] = {}
    for (sid, target), row in latest.items():
        count, last = overrides.get(row["id"], (0, None))
        entry = CriterionScore(
            criterion_id=target, status=row["status"], agent_score=_number(row["score"]),
            max_score=_number(row["max_score"]), rubric_version=int(row["rubric_version"]),
            justification=row["justification"] or "",
            evidence=_evidence(row["evidence"], f"criterion_score {row['id']}"),
            confidence=_number(row["confidence"]), no_data_reason=row["no_data_reason"],
            override=None if last is None else OverrideInfo(
                score=last["score"], reason=last["reason"], at=_iso(last["created_at"])),
            run_id=row["run_id"], version=count, criterion_name=names.get(target))
        result.setdefault(sid, {})[target] = CurrentScore(row["id"], entry)
    return result


def _load_overrides(session: Session, params: dict, only: str, record_ids: set[str]) -> dict[str, tuple[int, Any]]:
    """criterion_score_id -> (число правок, последняя правка)."""
    rows = session.execute(
        text("SELECT o.criterion_score_id, o.score, o.reason, o.created_at FROM score_override o "
             "JOIN submission s ON s.id = o.submission_id "
             f"WHERE s.project_id = :p{only} ORDER BY o.created_at, o.id"), params).mappings().all()
    result: dict[str, tuple[int, Any]] = {}
    for row in rows:
        if row["criterion_score_id"] in record_ids:
            count, _ = result.get(row["criterion_score_id"], (0, None))
            result[row["criterion_score_id"]] = (count + 1, row)
    return result


def _load_flags(session: Session, project_id: str, params: dict, only: str,
                criteria: list[CriterionDef]) -> dict[str, list[FlagInfo]]:
    mapper = _id_mapper(session, project_id, criteria)
    tasks = session.execute(
        text("SELECT rt.id, rt.submission_id, rt.role, r.created_at AS run_created FROM run_task rt "
             "JOIN run r ON r.id = rt.run_id JOIN submission s ON s.id = rt.submission_id "
             "WHERE r.project_id = :p AND s.deleted_at IS NULL AND rt.state IN ('done', 'failed', 'no_data')"
             f"{only} ORDER BY r.created_at, rt.id"), params).mappings().all()
    latest_task: dict[tuple[str, str], str] = {}
    for task in tasks:
        latest_task[(task["submission_id"], task["role"])] = task["id"]
    live = set(latest_task.values())
    rows = session.execute(
        text("SELECT f.id, f.run_task_id, f.submission_id, f.criterion_id, f.type, f.confidence, f.note, f.evidence, "
             "f.related_submission_id, f.related_url FROM flag f JOIN submission s ON s.id = f.submission_id "
             f"WHERE s.project_id = :p AND s.deleted_at IS NULL{only} ORDER BY f.created_at, f.id"),
        params).mappings().all()
    result: dict[str, list[FlagInfo]] = {}
    for row in rows:
        if row["run_task_id"] not in live or row["type"] not in FLAG_TYPES:
            continue
        result.setdefault(row["submission_id"], []).append(FlagInfo(
            type=row["type"], confidence=_number(row["confidence"]) or 0.0, note=row["note"] or "",
            evidence=_evidence(row["evidence"], f"flag {row['id']}"), criterion_id=mapper(row["criterion_id"]),
            related_submission_id=row["related_submission_id"], related_url=row["related_url"]))
    return result


# ─────────────────────────────── публичные функции ───────────────────────────────

def leaderboard(session: Session, project_id: str, *, sort: str = "total", order: str = "desc",
                flag: str | None = None) -> dict:
    """``Leaderboard``. ``ProjectNotFound`` — проекта нет; ``ValueError`` — неизвестные sort/order/flag."""
    data = _load(session, project_id)
    result = build_leaderboard(
        project_id=project_id, rubric=data.rubric, submissions=data.submissions, generated_at=utc_now_iso(),
        changed_criteria=data.changed, sort=sort, order=order, flag=flag)
    result["cost_usd"] = data.cost_usd
    return result


def find_current(session: Session, submission_id: str, criterion_id: str) -> tuple[_Data, CriterionDef, SubmissionScores]:
    """Данные одной работы и критерий подтверждённой версии; нет работы/критерия — ``ResultNotFound``."""
    project_id = session.execute(
        text("SELECT s.project_id FROM submission s JOIN project p ON p.id = s.project_id "
             "WHERE s.id = :id AND s.deleted_at IS NULL AND p.deleted_at IS NULL"),
        {"id": submission_id}).scalar()
    if project_id is None:
        raise ResultNotFound(submission_id)
    data = _load(session, project_id, submission_id)
    criteria = list(data.rubric.criteria) if data.rubric is not None else []
    criterion = next((c for c in criteria if c.id == criterion_id), None)
    if criterion is None or not data.submissions:
        raise ResultNotFound(criterion_id)
    return data, criterion, data.submissions[0]


def explanation(session: Session, submission_id: str, criterion_id: str) -> dict:
    """``Explanation`` критерия работы. ``ResultNotFound`` — нет работы или критерия текущей рубрики."""
    data, criterion, submission = find_current(session, submission_id, criterion_id)
    current = data.current.get((submission_id, criterion_id))
    return build_explanation(criterion=criterion, team_name=submission.team_name,
                             entry=current.entry if current is not None else None, flags=submission.flags)
