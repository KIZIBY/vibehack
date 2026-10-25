"""Ручная правка балла жюри (FR-027, T034).

Правка — новая строка append-only таблицы ``score_override`` для ТЕКУЩЕЙ записи ``criterion_score`` критерия;
исходный балл агента не меняется. ``expected_version`` сверяется с числом уже существующих правок этой записи
в том же операторе, что и вставка (``INSERT … SELECT … WHERE (SELECT COUNT(*) …) = :expected``): две конкурентные
правки с одной версией не пройдут обе. Функция пишет в переданную сессию и не делает commit.

Ошибки: ``ResultNotFound`` (404), ``OverrideInvalid`` (422), ``NoScoreToOverride`` (409 ``conflict``),
``VersionConflict`` из ``repositories.base`` (409 ``version_conflict``).
"""
from __future__ import annotations

import math
from typing import Any

from sqlalchemy import text
from sqlalchemy.orm import Session

from ..common import new_id, utc_now_iso
from ..repositories.base import VersionConflict
from .projects import touch_project
from .reports import clean_text
from .results import ResultNotFound, explanation, find_current

MIN_REASON = 3
MAX_REASON = 1000


class OverrideInvalid(ValueError):
    """Балл, причина или версия не прошли проверку (422)."""


class NoScoreToOverride(Exception):
    """У критерия работы нет записи оценки, к которой можно привязать правку (409 ``conflict``)."""


def _score(value: Any, max_score: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise OverrideInvalid("Балл должен быть числом")
    try:
        number = float(value)
    except OverflowError:
        raise OverrideInvalid("Балл вне допустимого диапазона") from None
    if not math.isfinite(number) or not 0 <= number <= max_score:
        raise OverrideInvalid(f"Балл должен быть числом от 0 до {max_score:g}")
    return number


def _reason(value: Any) -> str:
    if not isinstance(value, str):
        raise OverrideInvalid("Причина должна быть строкой")
    reason = clean_text(value, MAX_REASON * 4).strip()
    if not MIN_REASON <= len(reason) <= MAX_REASON:
        raise OverrideInvalid(f"Причина правки — от {MIN_REASON} до {MAX_REASON} символов")
    return reason


def _version(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise OverrideInvalid("expected_version должен быть целым числом не меньше 0")
    return value


def apply_override(session: Session, submission_id: str, criterion_id: str, *, score: Any, reason: Any,
                   expected_version: Any, actor: str) -> dict:
    """Записывает правку и возвращает обновлённое ``Explanation``."""
    data, criterion, _ = find_current(session, submission_id, criterion_id)
    current = data.current.get((submission_id, criterion_id))
    if current is None:
        raise NoScoreToOverride("Нет оценки для правки")
    value = _score(score, criterion.max_score)
    cleaned = _reason(reason)
    expected = _version(expected_version)

    if session.get_bind().dialect.name == "postgresql":   # сериализуем конкурентные правки одной записи
        session.execute(text("SELECT id FROM criterion_score WHERE id = :id FOR UPDATE"), {"id": current.record_id})
    result = session.execute(
        text("INSERT INTO score_override (id, criterion_score_id, submission_id, criterion_id, score, reason, actor, "
             "created_at) SELECT :id, :record, :sub, :cid, :score, :reason, :actor, :now "
             "WHERE (SELECT COUNT(*) FROM score_override WHERE criterion_score_id = :record) = :expected"),
        {"id": new_id(), "record": current.record_id, "sub": submission_id, "cid": _record_criterion(session, current),
         "score": value, "reason": cleaned, "actor": actor, "now": utc_now_iso(), "expected": expected})
    if result.rowcount != 1:
        raise VersionConflict(f"score_override: версия {expected} устарела")
    touch_project(session, data.project_id)
    return explanation(session, submission_id, criterion_id)


def _record_criterion(session: Session, current) -> str:
    """criterion_id самой записи оценки (у записи прошлой версии рубрики он свой)."""
    return session.execute(text("SELECT criterion_id FROM criterion_score WHERE id = :id"),
                           {"id": current.record_id}).scalar_one()


__all__ = ["NoScoreToOverride", "OverrideInvalid", "ResultNotFound", "apply_override"]
