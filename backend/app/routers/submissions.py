"""Работы: POST/GET /api/v1/projects/{id}/submissions, POST …/submissions:batch, GET /api/v1/submissions/{id}."""
from typing import Annotated, Optional

from fastapi import APIRouter, BackgroundTasks, File, Form, HTTPException, Request, UploadFile

from ..db import SessionDep
from ..services import intake_flow
from ..services import submissions as service

router = APIRouter()


def _project_not_found() -> HTTPException:
    return HTTPException(404, "Проект не найден")


@router.get("/api/v1/projects/{project_id}/submissions")
def list_submissions(project_id: str, session: SessionDep) -> dict:
    try:
        return {"items": service.list_submissions(session, project_id)}
    except LookupError:
        raise _project_not_found() from None


@router.post("/api/v1/projects/{project_id}/submissions", status_code=201)
async def create_submission(project_id: str, request: Request, background: BackgroundTasks,
                            team_name: Annotated[str, Form()],
                            files: Annotated[Optional[list[UploadFile]], File()] = None,
                            links: Annotated[Optional[str], Form()] = None) -> dict:
    try:
        summary = await service.create_submission(request.app, project_id, team_name, files or [], links)
    except LookupError:
        raise _project_not_found() from None
    except service.InvalidSubmission as error:
        raise HTTPException(422, str(error)) from None
    except service.DuplicateTeam:
        raise HTTPException(409, "Команда с таким названием уже есть в проекте") from None
    background.add_task(intake_flow.run_intake, request.app, project_id, summary["id"])
    return summary


@router.post("/api/v1/projects/{project_id}/submissions:batch", status_code=201)
async def create_batch(project_id: str, request: Request, background: BackgroundTasks,
                       table: Annotated[Optional[UploadFile], File()] = None,
                       archive: Annotated[Optional[UploadFile], File()] = None) -> dict:
    try:
        result = await service.create_batch(request.app, project_id, table, archive)
    except LookupError:
        raise _project_not_found() from None
    except service.InvalidSubmission as error:
        raise HTTPException(422, str(error)) from None
    if result["items"]:
        background.add_task(intake_flow.run_intake_batch, request.app, project_id, [item["id"] for item in result["items"]])
    return result


@router.get("/api/v1/submissions/{submission_id}")
def get_submission(submission_id: str, session: SessionDep) -> dict:
    try:
        return service.get_submission(session, submission_id)
    except LookupError:
        raise HTTPException(404, "Работа не найдена") from None
