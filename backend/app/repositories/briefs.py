"""SQL-доступ к таблице brief (SQLAlchemy Core, только именованные параметры)."""
from typing import Any, Optional

from sqlalchemy import text
from sqlalchemy.orm import Session

INSERT_COLUMNS = ("id", "project_id", "name", "source", "status", "reason", "path", "extracted_text_path", "created_at")


def insert(session: Session, values: dict[str, Any]) -> None:
    session.execute(
        text(f"INSERT INTO brief ({', '.join(INSERT_COLUMNS)}) VALUES ({', '.join(':' + c for c in INSERT_COLUMNS)})"),
        {column: values.get(column) for column in INSERT_COLUMNS})


def get(session: Session, brief_id: str) -> Optional[dict[str, Any]]:
    row = session.execute(
        text("SELECT * FROM brief WHERE id = :id AND deleted_at IS NULL"), {"id": brief_id}).mappings().first()
    return dict(row) if row is not None else None


def list_for_project(session: Session, project_id: str) -> list[dict[str, Any]]:
    """Новые сверху; удалённые (deleted_at) скрыты."""
    rows = session.execute(
        text("SELECT * FROM brief WHERE project_id = :project_id AND deleted_at IS NULL "
             "ORDER BY created_at DESC, id DESC"), {"project_id": project_id})
    return [dict(row) for row in rows.mappings()]


def finish_processing(session: Session, brief_id: str, status: str, reason: Optional[str],
                      extracted_text_path: Optional[str]) -> bool:
    """processing → extracted|failed; False, если материал уже не в обработке (удалён, повторный вызов)."""
    result = session.execute(
        text("UPDATE brief SET status = :status, reason = :reason, extracted_text_path = :extracted_text_path "
             "WHERE id = :id AND status = 'processing' AND deleted_at IS NULL"),
        {"status": status, "reason": reason, "extracted_text_path": extracted_text_path, "id": brief_id})
    return result.rowcount == 1
