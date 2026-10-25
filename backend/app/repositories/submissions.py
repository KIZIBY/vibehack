"""SQL-доступ к таблицам submission и material (SQLAlchemy Core, только именованные параметры)."""
import json
from typing import Any, Optional

import sqlalchemy as sa
from sqlalchemy import text
from sqlalchemy.orm import Session

SUBMISSION_COLUMNS = ("id", "project_id", "team_name", "intake_status", "completeness", "missing", "inventory_path",
                      "version", "created_at")
MATERIAL_COLUMNS = ("id", "submission_id", "type", "source_kind", "source_ref", "status", "reason", "size_bytes")


def _decode(row: dict[str, Any]) -> dict[str, Any]:
    if isinstance(row.get("missing"), (str, bytes)):     # SQLite отдаёт JSON-колонку текстом
        row["missing"] = json.loads(row["missing"])
    return row


def insert_submission(session: Session, values: dict[str, Any]) -> None:
    statement = text(
        f"INSERT INTO submission ({', '.join(SUBMISSION_COLUMNS)}) VALUES ({', '.join(':' + c for c in SUBMISSION_COLUMNS)})"
    ).bindparams(sa.bindparam("missing", type_=sa.JSON(none_as_null=True)))
    session.execute(statement, {column: values.get(column) for column in SUBMISSION_COLUMNS})


def insert_material(session: Session, values: dict[str, Any]) -> None:
    session.execute(
        text(f"INSERT INTO material ({', '.join(MATERIAL_COLUMNS)}) VALUES ({', '.join(':' + c for c in MATERIAL_COLUMNS)})"),
        {column: values.get(column) for column in MATERIAL_COLUMNS})


def team_names(session: Session, project_id: str) -> list[str]:
    """Названия ВСЕХ работ проекта, включая удалённые: уникальность в БД их тоже учитывает."""
    rows = session.execute(text("SELECT team_name FROM submission WHERE project_id = :p"), {"p": project_id})
    return [row[0] for row in rows]


def list_for_project(session: Session, project_id: str) -> list[dict[str, Any]]:
    rows = session.execute(
        text("SELECT * FROM submission WHERE project_id = :p AND deleted_at IS NULL ORDER BY created_at, id"), {"p": project_id})
    return [_decode(dict(row)) for row in rows.mappings()]


def get(session: Session, submission_id: str) -> Optional[dict[str, Any]]:
    """Работа живого проекта; удалённая работа или удалённый проект — None."""
    row = session.execute(
        text("SELECT s.* FROM submission s JOIN project p ON p.id = s.project_id "
             "WHERE s.id = :id AND s.deleted_at IS NULL AND p.deleted_at IS NULL"), {"id": submission_id}).mappings().first()
    return _decode(dict(row)) if row is not None else None


def materials_of(session: Session, submission_id: str) -> list[dict[str, Any]]:
    rows = session.execute(text("SELECT * FROM material WHERE submission_id = :s ORDER BY id"), {"s": submission_id})
    return [dict(row) for row in rows.mappings()]


def claim_pending(session: Session, project_id: str, submission_id: str) -> bool:
    """pending → running одним UPDATE: проигравший гонку получает False."""
    result = session.execute(
        text("UPDATE submission SET intake_status = 'running', version = version + 1 "
             "WHERE id = :id AND project_id = :p AND intake_status = 'pending' AND deleted_at IS NULL"),
        {"id": submission_id, "p": project_id})
    return result.rowcount == 1


def mark_failed(session: Session, submission_id: str) -> None:
    session.execute(
        text("UPDATE submission SET intake_status = 'failed', version = version + 1 "
             "WHERE id = :id AND intake_status = 'running'"), {"id": submission_id})


def mark_ready(session: Session, submission_id: str, *, completeness: str, missing: list, inventory_path: str) -> bool:
    statement = text(
        "UPDATE submission SET intake_status = 'ready', completeness = :completeness, missing = :missing, "
        "inventory_path = :inventory_path, version = version + 1 "
        "WHERE id = :id AND intake_status = 'running' AND deleted_at IS NULL"
    ).bindparams(sa.bindparam("missing", type_=sa.JSON))
    result = session.execute(statement, {"id": submission_id, "completeness": completeness, "missing": missing,
                                         "inventory_path": inventory_path})
    return result.rowcount == 1


def update_material(session: Session, submission_id: str, material_id: str, values: dict[str, Any]) -> None:
    session.execute(
        text("UPDATE material SET type = :type, status = :status, reason = :reason, "
             "size_bytes = COALESCE(:size_bytes, size_bytes) WHERE id = :id AND submission_id = :s"),
        {"id": material_id, "s": submission_id, "type": values["type"], "status": values["status"],
         "reason": values.get("reason"), "size_bytes": values.get("size_bytes")})
