"""Прогоны оценки: POST/GET /api/v1/projects/{id}/runs, GET /api/v1/runs/{run_id} (contracts/openapi.yaml, T032)."""
import asyncio
from typing import Literal, Optional

from fastapi import APIRouter, FastAPI, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, Field

from ..db import SessionDep, session_scope
from ..services import orchestrator
from ..services.projects import get_project
from ..state import get_gateway, get_storage
from .events import get_event_bus

router = APIRouter()

ScoringRole = Literal["code", "business", "design", "critic-uniqueness", "critic-honesty"]
MAX_IDS = 1000


class StartRun(BaseModel):
    """Пустые списки и отсутствующие поля значат «все»."""

    submission_ids: list[str] = Field(default_factory=list, max_length=MAX_IDS)
    roles: list[ScoringRole] = Field(default_factory=list, max_length=len(orchestrator.SCORING_ROLES) * 2)
    criterion_ids: list[str] = Field(default_factory=list, max_length=MAX_IDS)


def _create(app: FastAPI, project_id: str, body: StartRun):
    with session_scope(app.state.session_factory) as session:
        try:
            get_project(session, project_id)
        except LookupError:
            raise HTTPException(404, "Проект не найден") from None
        gateway = get_gateway(app)
        if gateway is None:
            raise HTTPException(503, "Шлюз агентов не настроен")
        try:
            run = orchestrator.create_run(
                session, storage=get_storage(app), project_id=project_id, submission_ids=body.submission_ids,
                roles=body.roles, criterion_ids=body.criterion_ids)
        except orchestrator.RunConflict as error:
            raise HTTPException(409, str(error)) from None
        except orchestrator.InvalidRunRequest as error:
            raise HTTPException(422, str(error)) from None
    return run, gateway


def launch_run(app: FastAPI, gateway, run_id: str) -> asyncio.Task:
    """Запускает выполнение прогона в фоне; ссылка на задачу хранится в ``app.state.run_jobs`` (иначе её соберёт GC)."""
    jobs = getattr(app.state, "run_jobs", None)
    if jobs is None:
        jobs = app.state.run_jobs = set()
    settings = app.state.settings
    runner = orchestrator.Orchestrator(
        app.state.session_factory, gateway, settings.data_dir, get_event_bus(app),
        max_parallel=settings.max_parallel_submissions, sleep=getattr(app.state, "run_sleep", None) or asyncio.sleep)
    job = asyncio.create_task(runner.execute(run_id))
    jobs.add(job)
    job.add_done_callback(jobs.discard)
    return job


@router.post("/api/v1/projects/{project_id}/runs", status_code=202)
async def start_run(project_id: str, request: Request, body: Optional[StartRun] = None) -> dict:
    run, gateway = await run_in_threadpool(_create, request.app, project_id, body or StartRun())
    launch_run(request.app, gateway, run["id"])    # после коммита: фон видит созданные строки
    return run


@router.get("/api/v1/projects/{project_id}/runs")
def list_runs(project_id: str, session: SessionDep) -> dict:
    try:
        return {"items": orchestrator.list_runs(session, project_id)}
    except LookupError:
        raise HTTPException(404, "Проект не найден") from None


@router.get("/api/v1/runs/{run_id}")
def get_run(run_id: str, session: SessionDep) -> dict:
    run = orchestrator.get_run(session, run_id)
    if run is None:
        raise HTTPException(404, "Прогон не найден")
    return run
