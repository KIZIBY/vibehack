"""GET/POST /api/v1/projects/{project_id}/messages (contracts/openapi.yaml)."""
from typing import Annotated, Optional

from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import BaseModel, StringConstraints

from ..db import SessionDep
from ..services import briefs as briefs_service
from ..services import messages as service
from ..state import get_storage

router = APIRouter(prefix="/api/v1/projects/{project_id}/messages")


class MessageCreate(BaseModel):
    text: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=20000)]


@router.get("")
def list_messages(project_id: str, session: SessionDep, after: Optional[str] = None,
                  limit: Annotated[int, Query(ge=1, le=200)] = 50) -> dict:
    try:
        return service.list_messages(session, project_id, limit=limit, after=after)
    except LookupError:
        raise HTTPException(404, "Проект не найден") from None
    except ValueError:
        raise HTTPException(422, "Некорректный курсор after") from None


@router.post("", status_code=201)
async def post_message(project_id: str, body: MessageCreate, session: SessionDep, request: Request) -> dict:
    try:
        message = service.post_organizer_message(session, project_id, body.text)
    except LookupError:
        raise HTTPException(404, "Проект не найден") from None
    # на этапе настройки текст организатора — ещё и вводный материал; сбой записи сообщение не теряет
    await briefs_service.add_chat_brief(session, get_storage(request.app), project_id, body.text)
    return message
