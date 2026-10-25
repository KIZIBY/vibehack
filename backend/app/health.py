"""GET /health — живость без авторизации; состояние шлюза агентов не делает статус ошибкой (устав I-8)."""
import asyncio
import logging

from fastapi import APIRouter, Request

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
    return {
        "status": "ok",
        "agents": await agents_state(state.agent_probe, state.agent_probe_timeout),
        "version": state.settings.version,
    }
