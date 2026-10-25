"""SQL-доступ к таблице message (SQLAlchemy Core, только именованные параметры)."""
import json
from typing import Any, Optional

import sqlalchemy as sa
from sqlalchemy import text
from sqlalchemy.orm import Session

from .base import keyset_page


def _decode(row: dict[str, Any]) -> dict[str, Any]:
    if isinstance(row.get("attachments"), (str, bytes)):   # SQLite отдаёт JSON-колонку текстом
        row["attachments"] = json.loads(row["attachments"])
    return row


def insert(session: Session, values: dict[str, Any]) -> None:
    statement = text(
        "INSERT INTO message (id, project_id, author, kind, text, attachments, created_at) "
        "VALUES (:id, :project_id, :author, :kind, :text, :attachments, :created_at)"
    ).bindparams(sa.bindparam("attachments", type_=sa.JSON(none_as_null=True)))   # None → SQL NULL, не JSON 'null'
    session.execute(statement, values)


def page(session: Session, project_id: str, *, limit: int, after: Optional[str]
         ) -> tuple[list[dict[str, Any]], Optional[str]]:
    """Старые → новые; ключ курсора (created_at, id). Неверный курсор — ValueError."""
    rows, next_cursor = keyset_page(
        session, "message", limit=limit, after=after, where="project_id = :project_id",
        params={"project_id": project_id})
    return [_decode(row) for row in rows], next_cursor
