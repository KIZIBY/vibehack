"""Вызов intake после создания работы: pending → running → ready|failed, перенос описи в БД, сообщение и событие."""
import asyncio
import json
import logging
from typing import Optional

from fastapi import FastAPI

from ..common import new_id
from ..db import session_scope
from ..repositories import submissions as repo
from ..routers.events import get_event_bus
from ..state import get_intake_runner, get_storage
from . import messages
from .intake_runner import INVENTORY_NAME, IntakeFailed
from .submissions import submission_dir

logger = logging.getLogger(__name__)

LINKS_NAME = "links.json"
DEFAULT_PARALLEL = 3
TYPE_LABELS = {
    "repository": "репозиторий", "host": "ссылка на работающий продукт", "presentation": "презентация",
    "screencast": "скринкаст", "archive": "архив", "code_file": "файл с кодом", "document": "документ",
    "image": "изображение", "metrics_row": "строка метрик", "other": "прочее",
}


def _claim(app: FastAPI, project_id: str, submission_id: str) -> bool:
    with session_scope(app.state.session_factory) as session:
        return repo.claim_pending(session, project_id, submission_id)


def _prepare(app: FastAPI, project_id: str, submission_id: str):
    """Каталог работы и манифест ссылок ``links.json`` для intake (ссылки в каталоге иначе не лежат)."""
    with session_scope(app.state.session_factory) as session:
        links = [{"material_id": m["id"], "type": m["type"], "url": m["source_ref"]}
                 for m in repo.materials_of(session, submission_id) if m["source_kind"] == "url"]
    directory = submission_dir(get_storage(app), project_id, submission_id)
    directory.mkdir(parents=True, exist_ok=True)
    if links:
        (directory / LINKS_NAME).write_text(json.dumps(links, ensure_ascii=False), encoding="utf-8")
    return directory


def _mark_failed(app: FastAPI, submission_id: str) -> None:
    with session_scope(app.state.session_factory) as session:
        repo.mark_failed(session, submission_id)


def _source_of(material: dict) -> tuple:
    source = material.get("source") or {}
    kind = source.get("kind")
    return kind, source.get("url") if kind == "url" else source.get("path")


def _sync_materials(session, submission_id: str, inventory: dict) -> None:
    current = repo.materials_of(session, submission_id)
    by_id = {row["id"]: row for row in current}
    by_source = {(row["source_kind"], row["source_ref"]): row["id"] for row in current if row["source_ref"]}
    used: set = set()
    for material in inventory.get("materials", []):
        kind, reference = _source_of(material)
        target = material["material_id"] if material["material_id"] in by_id else by_source.get((kind, reference))
        values = {"type": material["type"], "status": material["status"], "reason": material.get("reason"),
                  "size_bytes": material.get("size_bytes")}
        if target is not None and target not in used:
            used.add(target)
            repo.update_material(session, submission_id, target, values)
        else:
            new_material_id = new_id()
            used.add(new_material_id)
            repo.insert_material(session, {"id": new_material_id, "submission_id": submission_id, "source_kind": kind,
                                          "source_ref": reference, **values})


def _message_text(team_name: str, completeness: dict) -> str:
    if completeness["status"] == "complete":
        return f"Опись «{team_name}» готова: полная."
    missing = ", ".join(TYPE_LABELS.get(item, str(item)) for item in completeness.get("missing", []))
    return f"Опись «{team_name}» готова: не хватает — {missing or 'части материалов'}."


def _apply(app: FastAPI, project_id: str, submission_id: str, inventory: dict) -> Optional[str]:
    """Записывает опись одной транзакцией; возвращает completeness или None, если работу удалили за это время."""
    completeness = inventory["completeness"]
    path = "/".join(("projects", project_id, "submissions", submission_id, INVENTORY_NAME))
    with session_scope(app.state.session_factory) as session:
        row = repo.get(session, submission_id)
        if row is None or not repo.mark_ready(session, submission_id, completeness=completeness["status"],
                                              missing=list(completeness.get("missing", [])), inventory_path=path):
            return None
        _sync_materials(session, submission_id, inventory)
        try:
            messages.post_system_message(session, project_id, "inventory_ready",
                                         _message_text(row["team_name"], completeness))
        except LookupError:         # проект удалили между проверкой и записью — сообщение некому показывать
            pass
    return completeness["status"]


async def run_intake(app: FastAPI, project_id: str, submission_id: str) -> None:
    """Фоновый запуск intake для работы. Не бросает исключений: сбой — ``intake_status=failed`` и строка в логе."""
    try:
        if not await asyncio.to_thread(_claim, app, project_id, submission_id):
            return          # уже запущено, закончено или работы нет
        try:
            directory = await asyncio.to_thread(_prepare, app, project_id, submission_id)
            inventory = await get_intake_runner(app).run(directory, directory)
            if inventory.get("submission_id") != submission_id or inventory.get("project_id") != project_id:
                logger.error("опись работы %s относится к другой работе или проекту", submission_id)
                await asyncio.to_thread(_mark_failed, app, submission_id)
                return
            status = await asyncio.to_thread(_apply, app, project_id, submission_id, inventory)
        except IntakeFailed as error:
            logger.error("intake не дал описи для работы %s: %s", submission_id, error.reason)
            await asyncio.to_thread(_mark_failed, app, submission_id)
            return
        except Exception as error:      # текст исключения может содержать пути машины — в лог только тип
            logger.error("сбой обработки описи работы %s: %s", submission_id, type(error).__name__)
            await asyncio.to_thread(_mark_failed, app, submission_id)
            return
        if status is not None:
            get_event_bus(app).publish(project_id, "submission.inventory_ready",
                                       {"submission_id": submission_id, "completeness": status})
    except Exception as error:          # последняя страховка: фоновая задача не должна ронять процесс
        logger.error("сбой запуска intake для работы %s: %s", submission_id, type(error).__name__)


async def run_intake_batch(app: FastAPI, project_id: str, submission_ids: list,
                           concurrency: Optional[int] = None) -> None:
    """Опись для нескольких работ, не больше ``max_parallel_submissions`` одновременно."""
    limit = concurrency or getattr(app.state.settings, "max_parallel_submissions", DEFAULT_PARALLEL) or DEFAULT_PARALLEL
    semaphore = asyncio.Semaphore(limit)

    async def one(submission_id: str) -> None:
        async with semaphore:
            await run_intake(app, project_id, submission_id)

    await asyncio.gather(*(one(submission_id) for submission_id in submission_ids))

