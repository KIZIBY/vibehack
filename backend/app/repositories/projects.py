"""SQL-доступ к таблице project (SQLAlchemy Core, только именованные параметры)."""
import json
from typing import Any, Optional

import sqlalchemy as sa
from sqlalchemy import text
from sqlalchemy.orm import Session

JSON_COLUMNS = ("agents", "required_materials")
INSERT_COLUMNS = ("id", "name", "type", "status", "starts_on", "ends_on", "agents", "required_materials",
                  "retention_days", "last_activity_at", "version", "created_at", "updated_at")


def _decode(row: dict[str, Any]) -> dict[str, Any]:
    for column in JSON_COLUMNS:
        if isinstance(row[column], (str, bytes)):   # SQLite отдаёт JSON-колонку текстом, Postgres — готовым объектом
            row[column] = json.loads(row[column])
    return row


def insert(session: Session, values: dict[str, Any]) -> None:
    statement = text(
        f"INSERT INTO project ({', '.join(INSERT_COLUMNS)}) VALUES ({', '.join(':' + c for c in INSERT_COLUMNS)})"
    ).bindparams(*(sa.bindparam(c, type_=sa.JSON) for c in JSON_COLUMNS))
    session.execute(statement, {column: values[column] for column in INSERT_COLUMNS})


def get(session: Session, project_id: str) -> Optional[dict[str, Any]]:
    row = session.execute(
        text("SELECT * FROM project WHERE id = :id AND deleted_at IS NULL"), {"id": project_id}).mappings().first()
    return _decode(dict(row)) if row is not None else None


def list_rows(session: Session, *, include_archived: bool) -> list[dict[str, Any]]:
    archived_filter = "" if include_archived else " AND status <> 'archived'"
    rows = session.execute(text(
        f"SELECT * FROM project WHERE deleted_at IS NULL{archived_filter} ORDER BY created_at DESC, id DESC"))
    return [_decode(dict(row)) for row in rows.mappings()]


def touch(session: Session, project_id: str, now: str) -> bool:
    result = session.execute(
        text("UPDATE project SET last_activity_at = CASE WHEN last_activity_at < :now THEN :now ELSE last_activity_at END "
             "WHERE id = :id AND deleted_at IS NULL"),   # монотонно: параллельная запись не сдвигает срок хранения назад
        {"now": now, "id": project_id})
    return result.rowcount == 1


def change_status(session: Session, project_id: str, current: str, target: str, now: str) -> bool:
    """Смена статуса с проверкой текущего значения: параллельная смена не затирается; версия растёт."""
    result = session.execute(
        text("UPDATE project SET status = :target, version = version + 1, updated_at = :now, "
             "last_activity_at = CASE WHEN last_activity_at < :now THEN :now ELSE last_activity_at END "
             "WHERE id = :id AND status = :current AND deleted_at IS NULL"),
        {"target": target, "current": current, "now": now, "id": project_id})
    return result.rowcount == 1
