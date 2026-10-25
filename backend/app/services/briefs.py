"""Вводные материалы проекта: загрузка файлов и ссылок, текст из чата, фоновое извлечение текста (T025)."""
import asyncio
import json
import logging
import shutil
from pathlib import Path
from typing import Any, AsyncIterator, Optional

from sqlalchemy.orm import Session

from ..common import new_id, utc_now_iso
from ..db import session_scope
from ..repositories import briefs as repo
from ..routers.events import get_event_bus
from ..state import get_intake_runner, get_storage
from .intake_runner import IntakeFailed
from .messages import post_system_message
from .netguard import validate_public_url
from .projects import get_project, touch_project
from .storage import Storage, UnsafePath, safe_join

log = logging.getLogger(__name__)

MAX_FILE_BYTES = 100 * 1024 * 1024
MAX_FILES = 20
MAX_LINKS = 20
CHAT_BRIEF_MAX_BYTES = 1024 * 1024
READ_CHUNK_BYTES = 256 * 1024
LINK_REASON = "ссылка сохранена без извлечения"
REASON_NO_TEXT = "в материале не найден текст"
REASON_TIMEOUT = "превышено время обработки материала"
REASON_GENERIC = "не удалось обработать материал"


class InvalidBriefs(ValueError):
    """Запрос на загрузку вводных некорректен (пустой, слишком много файлов или ссылок, плохое поле links)."""


class _NoText(Exception):
    pass


def brief_view(row: dict[str, Any]) -> dict[str, Any]:
    """Строка БД → схема Brief; путей машины в ответе нет."""
    view = {"id": row["id"], "name": row["name"], "source": row["source"], "status": row["status"]}
    if row.get("reason") is not None:
        view["reason"] = row["reason"]
    return view


def list_briefs(session: Session, project_id: str) -> list[dict[str, Any]]:
    """LookupError — проекта нет или он удалён."""
    get_project(session, project_id)
    return [brief_view(row) for row in repo.list_for_project(session, project_id)]


def parse_links(raw: Optional[str]) -> list[str]:
    if raw is None:
        return []
    try:
        data = json.loads(raw)
    except ValueError:
        raise InvalidBriefs("links: ожидается JSON-массив ссылок") from None
    if not isinstance(data, list) or not all(isinstance(item, str) and item.strip() for item in data):
        raise InvalidBriefs("links: ожидается JSON-массив непустых строк")
    return data


async def _upload_chunks(upload: Any) -> AsyncIterator[bytes]:
    while True:
        data = await upload.read(READ_CHUNK_BYTES)
        if not data:
            return
        yield data


async def _bytes_chunks(data: bytes) -> AsyncIterator[bytes]:
    yield data


def _remove_material(storage: Storage, path_rel: str) -> None:
    """Убирает каталог материала (при откате запроса); ошибки уборки не маскируют исходную."""
    try:
        shutil.rmtree(safe_join(storage.root, path_rel.rsplit("/", 1)[0]), ignore_errors=True)
    except (UnsafePath, ValueError):
        pass


def _new_row(project_id: str, name: str, source: str, status: str, **extra: Any) -> dict[str, Any]:
    return {"id": new_id(), "project_id": project_id, "name": name, "source": source, "status": status,
            "created_at": utc_now_iso(), **extra}


async def create_briefs(session: Session, storage: Storage, project_id: str, uploads: list[Any],
                        raw_links: Optional[str]) -> tuple[list[dict[str, Any]], list[str]]:
    """Принимает файлы и ссылки. LookupError — нет проекта; InvalidBriefs/UnsafeUrl — 422; PayloadTooLarge — 413.

    Возвращает (Brief-ответы в порядке «файлы, ссылки», id файловых материалов для фонового извлечения).
    Всё или ничего: при сбое сохранённые в этом запросе файлы удаляются."""
    get_project(session, project_id)      # только чтение: блокировку записи БД не берём, пока файлы пишутся на диск
    links = parse_links(raw_links)
    if not uploads and not links:
        raise InvalidBriefs("нужен хотя бы один файл или одна ссылка")
    if len(uploads) > MAX_FILES:
        raise InvalidBriefs(f"не больше {MAX_FILES} файлов за запрос")
    if len(links) > MAX_LINKS:
        raise InvalidBriefs(f"не больше {MAX_LINKS} ссылок за запрос")
    urls = [await asyncio.to_thread(validate_public_url, link) for link in links]   # UnsafeUrl до любой записи

    saved_paths: list[str] = []
    try:
        for upload in uploads:
            saved = await storage.save_upload(project_id, "briefs", upload.filename or "", _upload_chunks(upload),
                                              max_bytes=MAX_FILE_BYTES)
            saved_paths.append(saved.path_rel)
        touch_project(session, project_id)      # запись в БД — одним коротким блоком после файлов
        views: list[dict[str, Any]] = []
        file_ids: list[str] = []
        for path_rel in saved_paths:
            row = _new_row(project_id, path_rel.rsplit("/", 1)[-1], "upload", "processing", path=path_rel)
            repo.insert(session, row)
            views.append(brief_view(row))
            file_ids.append(row["id"])
        for url in urls:
            row = _new_row(project_id, url, "url", "extracted", reason=LINK_REASON)
            repo.insert(session, row)
            views.append(brief_view(row))
        session.commit()        # сбой фиксации — файлы ниже не остаются без строк brief
    except BaseException:
        for path_rel in saved_paths:
            _remove_material(storage, path_rel)
        raise
    return views, file_ids


async def add_chat_brief(session: Session, storage: Storage, project_id: str, text: str) -> Optional[dict[str, Any]]:
    """Текст организатора из чата как вводный (только проект в статусе setup). Сбой записи сообщение не теряет:
    ошибка уходит в лог, brief не создаётся."""
    if get_project(session, project_id)["status"] != "setup":
        return None
    try:
        saved = await storage.save_upload(project_id, "briefs", f"chat-{new_id()}.md", _bytes_chunks(text.encode("utf-8")),
                                          max_bytes=CHAT_BRIEF_MAX_BYTES)
    except Exception:
        log.exception("не удалось сохранить текст чата как вводный материал", extra={"project_id": project_id})
        return None
    try:
        row = _new_row(project_id, saved.path_rel.rsplit("/", 1)[-1], "chat", "extracted", path=saved.path_rel,
                       extracted_text_path=saved.path_rel)
        repo.insert(session, row)
        session.commit()        # сообщение и вводный фиксируются вместе; сбой — файл не остаётся без строки brief
    except BaseException:
        _remove_material(storage, saved.path_rel)
        raise
    return brief_view(row)


# ─────────────────────────────── фоновое извлечение ───────────────────────────────

def _checked_text_path(inventory: dict[str, Any], root: Path, out_dir: Path) -> str:
    """Первая запись описи с extracted.text_path; путь обязан вести на обычный файл внутри каталога результата."""
    for material in inventory.get("materials", []):
        candidate = (material.get("extracted") or {}).get("text_path")
        if not candidate:
            continue
        if not isinstance(candidate, str):
            raise _NoText
        try:
            target = safe_join(root, candidate)      # абсолютный путь, «..», симлинки наружу → UnsafePath
        except UnsafePath:
            raise _NoText from None
        if not target.is_relative_to(out_dir.resolve()) or not target.is_file():
            raise _NoText
        return target.relative_to(root.resolve()).as_posix()
    raise _NoText


async def _extract_text(app: Any, path_rel: str) -> str:
    root = Path(get_storage(app).root)
    material_rel = path_rel.rsplit("/", 1)[0]
    material_dir = safe_join(root, material_rel)
    out_dir = safe_join(root, material_rel, "extracted")
    inventory = await get_intake_runner(app).run(material_dir, out_dir)
    return _checked_text_path(inventory, root, out_dir)


async def _extract_one(app: Any, project_id: str, brief_id: str) -> None:
    factory = app.state.session_factory
    with session_scope(factory) as session:
        row = repo.get(session, brief_id)
    if row is None or row["status"] != "processing" or not row["path"]:
        return
    name = row["name"]
    status, reason, text_path = "failed", REASON_GENERIC, None
    try:
        text_path = await _extract_text(app, row["path"])
        status, reason = "extracted", None
    except _NoText:
        reason = REASON_NO_TEXT
    except IntakeFailed as error:
        reason = REASON_TIMEOUT if error.reason == "timeout" else REASON_GENERIC
        log.warning("intake не обработал вводный материал", extra={"brief_id": brief_id, "reason": error.reason})
    except Exception:
        log.exception("сбой извлечения текста вводного материала", extra={"brief_id": brief_id})
    message = None
    with session_scope(factory) as session:
        if not repo.finish_processing(session, brief_id, status, reason, text_path):
            return
        text = f"{name}: текст извлечён" if status == "extracted" else f"{name}: не удалось извлечь материал"
        try:
            message = post_system_message(session, project_id, "brief_extracted", text)
        except LookupError:      # проект удалён, пока шло извлечение
            message = None
    if message is not None:
        get_event_bus(app).publish(project_id, "message.created", {"message_id": message["id"]})


async def extract_briefs(app: Any, project_id: str, brief_ids: list[str]) -> None:
    """Фоновая задача после ответа: материалы обрабатываются по одному; ни один сбой не выходит наружу."""
    for brief_id in brief_ids:
        try:
            await _extract_one(app, project_id, brief_id)
        except Exception:
            log.exception("сбой фоновой обработки вводного материала", extra={"brief_id": brief_id})
