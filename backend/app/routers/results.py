"""Результаты: таблица оценок, пояснение балла, ручная правка (contracts/openapi.yaml, T034)."""
from typing import Optional, Union

from fastapi import APIRouter, BackgroundTasks, HTTPException, Request
from pydantic import BaseModel, Field, StrictFloat, StrictInt
from sqlalchemy import text

from ..db import SessionDep
from ..services import overrides, results
from ..services.rubric import ProjectNotFound
from .events import get_event_bus

router = APIRouter(prefix="/api/v1")

Number = Union[StrictInt, StrictFloat]


class OverrideBody(BaseModel):
    score: Number
    reason: str = Field(max_length=5000)   # длина после очистки проверяется в сервисе
    expected_version: StrictInt = Field(ge=0)


@router.get("/projects/{project_id}/leaderboard")
def get_leaderboard(project_id: str, session: SessionDep, sort: str = "total", order: str = "desc",
                    flag: Optional[str] = None) -> dict:
    try:
        return results.leaderboard(session, project_id, sort=sort, order=order, flag=flag)
    except ProjectNotFound:
        raise HTTPException(404, "Проект не найден") from None
    except ValueError as exc:
        raise HTTPException(422, f"Неверные параметры таблицы: {exc}") from None


@router.get("/submissions/{submission_id}/criteria/{criterion_id}")
def get_explanation(submission_id: str, criterion_id: str, session: SessionDep) -> dict:
    try:
        return results.explanation(session, submission_id, criterion_id)
    except results.ResultNotFound:
        raise HTTPException(404, "Работа или критерий не найдены") from None


@router.put("/submissions/{submission_id}/criteria/{criterion_id}/override")
def override_score(submission_id: str, criterion_id: str, body: OverrideBody, request: Request,
                   session: SessionDep, background: BackgroundTasks) -> dict:
    try:
        explained = overrides.apply_override(
            session, submission_id, criterion_id, score=body.score, reason=body.reason,
            expected_version=body.expected_version, actor=request.state.session.username)
        project_id = session.execute(
            text("SELECT project_id FROM submission WHERE id = :id"), {"id": submission_id}).scalar_one()
    except results.ResultNotFound:
        raise HTTPException(404, "Работа или критерий не найдены") from None
    except overrides.OverrideInvalid as exc:
        raise HTTPException(422, str(exc)) from None
    except overrides.NoScoreToOverride as exc:
        raise HTTPException(409, str(exc)) from None
    # событие уходит после ответа, то есть после commit сессии запроса: подписчик перечитает уже сохранённое
    background.add_task(get_event_bus(request.app).publish, project_id, "score.changed",
                        {"submission_id": submission_id, "criterion_id": criterion_id})
    return explained
