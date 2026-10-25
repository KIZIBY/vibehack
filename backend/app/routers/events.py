"""SSE-поток событий проекта: GET /api/v1/projects/{project_id}/events."""
import asyncio
import json
import re
import threading
from typing import AsyncIterator, Optional

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse
from starlette.background import BackgroundTask

from ..services.events import Event, EventBus, Subscription

router = APIRouter()

PROJECT_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")
LAST_EVENT_ID_RE = re.compile(r"[0-9]{1,18}")
DEFAULT_HEARTBEAT = 15.0
HEARTBEAT_FRAME = ": ping\n\n"
_bus_lock = threading.Lock()


def get_event_bus(app) -> EventBus:
    """Шина приложения: ``app.state.event_bus`` или лениво созданная."""
    bus = getattr(app.state, "event_bus", None)
    if bus is None:
        with _bus_lock:
            bus = getattr(app.state, "event_bus", None)
            if bus is None:
                bus = app.state.event_bus = EventBus()
    return bus


def format_frame(event: Event) -> str:
    data = json.dumps(event.data, ensure_ascii=False)
    return f"id: {event.id}\nevent: {event.type}\ndata: {data}\n\n"


def parse_last_event_id(value: Optional[str]) -> Optional[int]:
    """Мусорный заголовок игнорируется (как будто его нет)."""
    if value is not None and LAST_EVENT_ID_RE.fullmatch(value.strip()):
        return int(value.strip())
    return None


async def event_stream(subscription: Subscription, *, heartbeat: float = DEFAULT_HEARTBEAT) -> AsyncIterator[str]:
    """Кадры SSE; при завершении, отмене и обрыве клиента подписка закрывается."""
    try:
        while True:
            try:
                event = await asyncio.wait_for(subscription.__anext__(), heartbeat)
            except asyncio.TimeoutError:
                yield HEARTBEAT_FRAME
                continue
            except StopAsyncIteration:
                return
            yield format_frame(event)
    finally:
        await subscription.aclose()


@router.get("/api/v1/projects/{project_id}/events")
async def project_events(project_id: str, request: Request) -> StreamingResponse:
    if not PROJECT_ID_RE.fullmatch(project_id):
        raise HTTPException(status_code=404, detail="Проект не найден")
    subscription = get_event_bus(request.app).subscribe(
        project_id, parse_last_event_id(request.headers.get("last-event-id")))
    heartbeat = getattr(request.app.state, "sse_heartbeat", DEFAULT_HEARTBEAT)
    return StreamingResponse(
        event_stream(subscription, heartbeat=heartbeat),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        background=BackgroundTask(subscription.aclose),     # подписка не течёт, если генератор не стартовал
    )
