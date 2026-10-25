"""Проекты: значения по умолчанию по типу (FR-003), статусы, срок хранения (FR-031), обновление по версии."""
import json
from datetime import date, datetime, timedelta, timezone
from typing import Any, Optional

from sqlalchemy.orm import Session

from ..common import new_id, utc_now_iso
from ..config import Settings
from ..repositories import projects as repo
from ..repositories.base import update_versioned

PRODUCT_AGENTS = ["code", "business", "design", "critic-uniqueness", "critic-honesty"]
TYPE_DEFAULTS: dict[str, tuple[list[str], list[str]]] = {
    "product_hackathon": (PRODUCT_AGENTS, ["repository"]),
    "ml_hackathon": (["code", "business", "critic-uniqueness", "critic-honesty"], ["repository", "presentation"]),
    "homework": (["code", "business", "critic-uniqueness", "critic-honesty"], []),
    "other": (PRODUCT_AGENTS, ["repository"]),
}
STATUSES = ("setup", "intake", "evaluating", "results", "archived")
TRANSITIONS: dict[str, tuple[str, ...]] = {
    "setup": ("intake", "archived"),
    "intake": ("evaluating", "archived"),
    "evaluating": ("results", "archived"),
    "results": ("evaluating", "archived"),   # results → evaluating: повторная оценка
    "archived": (),
}
UPDATABLE = ("name", "starts_on", "ends_on", "agents", "required_materials")


class InvalidProject(ValueError):
    """Данные проекта нарушают инвариант (например, ends_on раньше starts_on)."""


def as_datetime(value: Any) -> datetime:
    parsed = value if isinstance(value, datetime) else datetime.fromisoformat(str(value))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _date(value: Any) -> Optional[str]:
    if value is None:
        return None
    return value.isoformat() if isinstance(value, date) else str(value)[:10]


def project_view(row: dict[str, Any]) -> dict[str, Any]:
    """Строка БД → схема Project (contracts/openapi.yaml)."""
    purge_at = as_datetime(row["last_activity_at"]) + timedelta(days=row["retention_days"])
    return {
        "id": row["id"], "name": row["name"], "type": row["type"], "status": row["status"],
        "starts_on": _date(row["starts_on"]), "ends_on": _date(row["ends_on"]),
        "agents": row["agents"], "required_materials": row["required_materials"],
        "rubric_confirmed_version": row["rubric_confirmed_version"], "retention_days": row["retention_days"],
        "purge_at": purge_at.isoformat(), "cost_usd": None,   # суммирование стоимости — позже
        "version": row["version"], "created_at": as_datetime(row["created_at"]).isoformat(),
        "updated_at": as_datetime(row["updated_at"]).isoformat(),
    }


def _check_dates(starts_on: Any, ends_on: Any) -> None:
    starts_on, ends_on = _date(starts_on), _date(ends_on)   # из БД date (Postgres) или строка (SQLite)
    if starts_on and ends_on and ends_on < starts_on:   # ISO-даты сравниваются как строки
        raise InvalidProject("ends_on не может быть раньше starts_on")


def get_project(session: Session, project_id: str) -> dict[str, Any]:
    row = repo.get(session, project_id)
    if row is None:
        raise LookupError(f"проект {project_id!r} не найден")
    return row


def list_projects(session: Session, *, include_archived: bool = False) -> list[dict[str, Any]]:
    return [project_view(row) for row in repo.list_rows(session, include_archived=include_archived)]


def create_project(session: Session, settings: Settings, *, name: str, type: str,
                   starts_on: Optional[str] = None, ends_on: Optional[str] = None) -> dict[str, Any]:
    _check_dates(starts_on, ends_on)
    agents, required = TYPE_DEFAULTS[type]
    now = utc_now_iso()
    values = {
        "id": new_id(), "name": name, "type": type, "status": "setup", "starts_on": starts_on, "ends_on": ends_on,
        "agents": list(agents), "required_materials": list(required), "retention_days": settings.retention_days,
        "last_activity_at": now, "version": 1, "created_at": now, "updated_at": now,
    }
    repo.insert(session, values)
    return project_view(get_project(session, values["id"]))


def update_project(session: Session, project_id: str, expected_version: int, changes: dict[str, Any],
                   archived: Optional[bool] = None) -> dict[str, Any]:
    """Частичное обновление. LookupError — проекта нет; VersionConflict — устаревшая версия; InvalidProject — даты."""
    row = get_project(session, project_id)
    values: dict[str, Any] = {key: changes[key] for key in UPDATABLE if key in changes}
    _check_dates(values.get("starts_on", row["starts_on"]), values.get("ends_on", row["ends_on"]))
    if archived is True and row["status"] != "archived":
        values["status"] = "archived"
    elif archived is False and row["status"] == "archived":
        values["status"] = "setup" if row["rubric_confirmed_version"] is None else "intake"
    for key in ("agents", "required_materials"):
        if key in values:
            values[key] = json.dumps(values[key])
    now = utc_now_iso()
    values["updated_at"] = now
    update_versioned(session, "project", project_id, expected_version, values)
    touch_project(session, project_id)   # правка проекта — активность (срок хранения, FR-031)
    return project_view(get_project(session, project_id))


def advance_status(session: Session, project_id: str, target: str) -> None:
    """Переход по таблице TRANSITIONS; недопустимый — ValueError, неизвестный проект — LookupError."""
    if target not in STATUSES:
        raise ValueError(f"неизвестный статус {target!r}")
    current = get_project(session, project_id)["status"]
    if target not in TRANSITIONS[current]:
        raise ValueError(f"переход {current} → {target} недопустим")
    if not repo.change_status(session, project_id, current, target, utc_now_iso()):
        raise ValueError(f"статус проекта изменился параллельно (был {current})")


def touch_project(session: Session, project_id: str) -> None:
    """Обновляет last_activity_at (основа срока хранения, FR-031); версию проекта не меняет."""
    if not repo.touch(session, project_id, utc_now_iso()):
        raise LookupError(f"проект {project_id!r} не найден")
