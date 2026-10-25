"""GET/POST /api/v1/projects/{project_id}/briefs (contracts/openapi.yaml: listBriefs, uploadBriefs)."""
from typing import Annotated, Optional

from fastapi import APIRouter, BackgroundTasks, File, Form, HTTPException, Request, UploadFile

from ..db import SessionDep
from ..services import briefs as service
from ..state import get_storage

router = APIRouter(prefix="/api/v1/projects/{project_id}/briefs")


def _not_found() -> HTTPException:
    return HTTPException(404, "Проект не найден")


@router.get("")
def list_briefs(project_id: str, session: SessionDep) -> dict:
    try:
        return {"items": service.list_briefs(session, project_id)}
    except LookupError:
        raise _not_found() from None


@router.post("", status_code=201)
async def upload_briefs(project_id: str, request: Request, background_tasks: BackgroundTasks, session: SessionDep,
                        files: Annotated[Optional[list[UploadFile]], File()] = None,
                        links: Annotated[Optional[str], Form()] = None) -> dict:
    try:
        items, file_ids = await service.create_briefs(session, get_storage(request.app), project_id, files or [], links)
    except LookupError:
        raise _not_found() from None
    except service.InvalidBriefs as error:
        raise HTTPException(422, str(error)) from None
    if file_ids:
        background_tasks.add_task(service.extract_briefs, request.app, project_id, file_ids)
    return {"items": items}
