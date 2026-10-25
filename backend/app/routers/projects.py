"""GET/POST /api/v1/projects, GET/PATCH /api/v1/projects/{project_id} (contracts/openapi.yaml)."""
import re
from datetime import date
from typing import Annotated, Any, Literal, Optional

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, StrictBool, StrictInt, StringConstraints

from ..db import SessionDep
from ..services import projects as service

router = APIRouter(prefix="/api/v1/projects")

ProjectType = Literal["product_hackathon", "ml_hackathon", "homework", "other"]
ScoringRole = Literal["code", "business", "design", "critic-uniqueness", "critic-honesty", "human"]
MaterialType = Literal["repository", "host", "presentation", "screencast", "archive", "code_file", "document",
                       "image", "metrics_row", "other"]
Name = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)]
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _parse_date(value: Any) -> date:
    if not isinstance(value, str) or not DATE_RE.match(value):
        raise ValueError("ожидается дата в формате ГГГГ-ММ-ДД")
    return date.fromisoformat(value)


Day = Annotated[date, BeforeValidator(_parse_date)]


class ProjectCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: Name
    type: ProjectType
    starts_on: Optional[Day] = None
    ends_on: Optional[Day] = None


class ProjectUpdate(BaseModel):
    # Поля без Optional: явный null для них — 422, отсутствие — «не менять» (значение по умолчанию не проверяется).
    model_config = ConfigDict(extra="forbid")   # status и type через PATCH менять нельзя
    expected_version: Annotated[StrictInt, Field(ge=0)]
    name: Name = None
    starts_on: Optional[Day] = None
    ends_on: Optional[Day] = None
    agents: list[ScoringRole] = None
    required_materials: list[MaterialType] = None
    archived: StrictBool = None


def _not_found() -> HTTPException:
    return HTTPException(404, "Проект не найден")


def _unique(items: list[str]) -> list[str]:
    return list(dict.fromkeys(items))


@router.get("")
def list_projects(session: SessionDep, include_archived: bool = False) -> dict:
    return {"items": service.list_projects(session, include_archived=include_archived)}


@router.post("", status_code=201)
def create_project(body: ProjectCreate, session: SessionDep, request: Request) -> dict:
    try:
        return service.create_project(
            session, request.app.state.settings, name=body.name, type=body.type,
            starts_on=body.starts_on.isoformat() if body.starts_on else None,
            ends_on=body.ends_on.isoformat() if body.ends_on else None)
    except service.InvalidProject as error:
        raise HTTPException(422, str(error)) from None


@router.get("/{project_id}")
def get_project(project_id: str, session: SessionDep) -> dict:
    try:
        return service.project_view(service.get_project(session, project_id))
    except LookupError:
        raise _not_found() from None


@router.patch("/{project_id}")
def update_project(project_id: str, body: ProjectUpdate, session: SessionDep) -> dict:
    sent = body.model_fields_set
    changes: dict[str, Any] = {}
    for key in ("name", "starts_on", "ends_on", "agents", "required_materials"):
        if key in sent:
            value = getattr(body, key)
            if key in ("starts_on", "ends_on"):
                value = value.isoformat() if value else None
            elif key in ("agents", "required_materials"):
                value = _unique(value)
            changes[key] = value
    try:
        return service.update_project(session, project_id, body.expected_version, changes,
                                      archived=body.archived if "archived" in sent else None)
    except LookupError:
        raise _not_found() from None
    except service.InvalidProject as error:
        raise HTTPException(422, str(error)) from None
