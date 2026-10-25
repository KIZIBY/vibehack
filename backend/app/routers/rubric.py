"""Рубрика проекта: GET/PUT /rubric, POST /rubric/draft, POST /rubric/confirm (contracts/openapi.yaml, T027)."""
import logging
import threading
from typing import Optional, Union

from fastapi import APIRouter, BackgroundTasks, FastAPI, HTTPException, Request, Response
from pydantic import BaseModel, Field, StrictFloat, StrictInt

from ..db import SessionDep
from ..services import rubric as service

router = APIRouter(prefix="/api/v1/projects")
log = logging.getLogger(__name__)

Number = Union[StrictInt, StrictFloat]
_BUILDING_LOCK = threading.Lock()


class AnchorBody(BaseModel):
    score: Number
    meaning: str


class CriterionBody(BaseModel):
    id: Optional[str] = None   # приходит у существующего критерия; новая версия всё равно получает новые id
    name: str
    description: Optional[str] = None
    weight: Number
    max_score: Number
    agent: str
    anchors: Optional[list[AnchorBody]] = None
    source_ref: Optional[str] = None


class SaveBody(BaseModel):
    criteria: list[CriterionBody]
    expected_version: StrictInt = Field(ge=0)


class ConfirmBody(BaseModel):
    version: StrictInt = Field(ge=1)


def _not_found() -> HTTPException:
    return HTTPException(404, "Проект не найден")


@router.get("/{project_id}/rubric")
def get_rubric(project_id: str, session: SessionDep) -> dict:
    try:
        return service.get_state(session, project_id)
    except service.ProjectNotFound:
        raise _not_found() from None


@router.put("/{project_id}/rubric")
def save_rubric(project_id: str, body: SaveBody, session: SessionDep) -> dict:
    criteria = [item.model_dump() for item in body.criteria]
    try:
        return service.save_version(session, project_id, criteria, body.expected_version)
    except service.ProjectNotFound:
        raise _not_found() from None
    except service.RubricInvalid as exc:
        raise HTTPException(422, str(exc)) from None


@router.post("/{project_id}/rubric/confirm")
def confirm_rubric(project_id: str, body: ConfirmBody, session: SessionDep) -> dict:
    try:
        return service.confirm(session, project_id, body.version)
    except service.ProjectNotFound:
        raise _not_found() from None
    except service.RubricConflict as exc:
        raise HTTPException(409, str(exc)) from None


def _building(app: FastAPI) -> set:
    """Множество проектов, у которых черновик строится сейчас; создаётся лениво (вызывать под ``_BUILDING_LOCK``)."""
    building = getattr(app.state, "rubric_building", None)
    if building is None:
        building = set()
        app.state.rubric_building = building
    return building


async def _build_in_background(app: FastAPI, gateway, project_id: str) -> None:
    try:
        await service.build_draft(app.state.session_factory, gateway, app.state.settings.data_dir, project_id)
    except Exception as exc:  # noqa: BLE001 — build_draft сам не бросает, это страховка от потери флага
        log.error("построение черновика рубрики упало", extra={"project_id": project_id, "error": type(exc).__name__})
    finally:
        with _BUILDING_LOCK:
            _building(app).discard(project_id)


@router.post("/{project_id}/rubric/draft", status_code=202)
def request_rubric_draft(project_id: str, request: Request, background: BackgroundTasks,
                         session: SessionDep) -> Response:
    app = request.app
    try:
        service.ensure_project(session, project_id)
    except service.ProjectNotFound:
        raise _not_found() from None
    if not service.has_extracted_brief(session, project_id):
        raise HTTPException(409, "Нет вводных материалов с извлечённым текстом")
    gateway = getattr(app.state, "gateway", None)
    with _BUILDING_LOCK:
        building = _building(app)
        if project_id in building:
            raise HTTPException(409, "Черновик рубрики уже строится")
        if gateway is None:
            raise HTTPException(503, "Шлюз агентов не настроен")
        building.add(project_id)
    background.add_task(_build_in_background, app, gateway, project_id)
    return Response(status_code=202)
