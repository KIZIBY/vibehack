"""Сообщения чата: лента, текст организатора и системные сообщения других сервисов."""
from typing import Any, Optional

from sqlalchemy.orm import Session

from ..common import new_id, utc_now_iso
from ..repositories import messages as repo
from .projects import as_datetime, get_project, touch_project

AUTHORS = ("organizer", "agent", "system")
KINDS = ("text", "brief_extracted", "rubric_drafted", "inventory_ready", "run_progress", "run_completed", "warning")


def message_view(row: dict[str, Any]) -> dict[str, Any]:
    """Строка БД → схема Message; attachments есть в ответе только если были заданы."""
    view = {"id": row["id"], "author": row["author"], "kind": row["kind"], "text": row["text"],
            "created_at": as_datetime(row["created_at"]).isoformat()}
    if row.get("attachments") is not None:
        view["attachments"] = row["attachments"]
    return view


def _checked_attachments(attachments: Any) -> Optional[list[dict[str, str]]]:
    if attachments is None:
        return None
    if not isinstance(attachments, list):
        raise ValueError("attachments должен быть списком")
    checked = []
    for item in attachments:
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            raise ValueError("вложение — словарь с обязательным строковым name")
        entry = {"name": item["name"]}
        if "material_id" in item:
            if not isinstance(item["material_id"], str):
                raise ValueError("material_id должен быть строкой")
            entry["material_id"] = item["material_id"]
        checked.append(entry)
    return checked


def _create(session: Session, project_id: str, author: str, kind: str, text: str,
            attachments: Optional[list[dict[str, str]]]) -> dict[str, Any]:
    touch_project(session, project_id)   # LookupError, если проекта нет; активность — основа срока хранения
    row = {"id": new_id(), "project_id": project_id, "author": author, "kind": kind, "text": text,
           "attachments": attachments, "created_at": utc_now_iso()}
    repo.insert(session, row)
    return message_view(row)


def post_organizer_message(session: Session, project_id: str, text: str) -> dict[str, Any]:
    return _create(session, project_id, "organizer", "text", text, None)


def post_system_message(session: Session, project_id: str, kind: str, text: str, *, author: str = "system",
                        attachments: Optional[list[dict[str, str]]] = None) -> dict[str, Any]:
    """Сообщение от платформы/агента. ValueError — неверный kind, author или вложения; LookupError — нет проекта."""
    if not isinstance(kind, str) or kind not in KINDS:
        raise ValueError(f"неизвестный kind {kind!r}")
    if not isinstance(author, str) or author not in AUTHORS:
        raise ValueError(f"неизвестный author {author!r}")
    if not isinstance(text, str):
        raise ValueError("text должен быть строкой")
    return _create(session, project_id, author, kind, text, _checked_attachments(attachments))


def list_messages(session: Session, project_id: str, *, limit: int, after: Optional[str]) -> dict[str, Any]:
    """LookupError — нет проекта; ValueError — некорректный курсор."""
    get_project(session, project_id)
    rows, next_cursor = repo.page(session, project_id, limit=limit, after=after)
    return {"items": [message_view(row) for row in rows], "next_cursor": next_cursor}
