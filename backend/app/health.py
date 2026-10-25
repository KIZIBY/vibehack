"""GET /health — живость без авторизации; состояние шлюза агентов не делает статус ошибкой (устав I-8)."""
import asyncio
import logging

from fastapi import APIRouter, Request

from .state import get_gateway

router = APIRouter()
log = logging.getLogger(__name__)


async def agents_state(probe, timeout: float) -> str:
    if probe is None:
        return "unknown"
    try:
        answer = await asyncio.wait_for(probe(), timeout)
    except asyncio.TimeoutError:
        log.error("проба шлюза агентов не уложилась в %.1f с", timeout)
        return "down"
    except Exception:
        log.error("проба шлюза агентов упала", exc_info=True)
        return "down"
    return answer if answer in ("up", "down") else "unknown"


@router.get("/health")
async def health(request: Request):
    state = request.app.state
    probe = state.agent_probe
    if probe is None:
        gateway = get_gateway(request.app)
        probe = gateway.probe if gateway is not None else None
    return {
        "status": "ok",
        "agents": await agents_state(probe, state.agent_probe_timeout),
        "version": state.settings.version,
    }
