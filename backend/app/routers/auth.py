"""POST /api/v1/auth/login, POST /api/v1/auth/logout, GET /api/v1/auth/me (contracts/openapi.yaml)."""
import logging

from fastapi import APIRouter, HTTPException, Request, Response
from pydantic import BaseModel

from ..auth import SESSION_COOKIE, credentials_match, session_cookie

router = APIRouter(prefix="/api/v1/auth")
log = logging.getLogger(__name__)


class LoginBody(BaseModel):
    username: str
    password: str


@router.post("/login", status_code=204)
async def login(body: LoginBody, request: Request) -> Response:
    state = request.app.state
    settings = state.settings
    client = request.client.host if request.client else "unknown"
    retry_after = state.login_limiter.register(client)
    if retry_after is not None:
        log.warning("превышен лимит попыток входа", extra={"client": client})
        raise HTTPException(429, "Слишком много попыток входа", headers={"Retry-After": str(retry_after)})
    if not (settings.demo_user and settings.demo_password and state.sessions.configured):
        log.error("вход не настроен: нужны JUDGE_DEMO_USER, JUDGE_DEMO_PASSWORD, JUDGE_SESSION_SECRET")
        raise HTTPException(503, "Вход не настроен")
    if not credentials_match(settings.demo_user, settings.demo_password, body.username, body.password):
        log.warning("неудачная попытка входа", extra={"client": client})
        raise HTTPException(401, "Неверный логин или пароль")
    response = Response(status_code=204)
    response.headers["set-cookie"] = session_cookie(
        state.sessions.issue(settings.demo_user), secure=settings.cookie_secure
    )
    return response


@router.post("/logout", status_code=204)
async def logout(request: Request) -> Response:
    request.app.state.sessions.revoke(request.state.session)
    response = Response(status_code=204)
    response.delete_cookie(SESSION_COOKIE, path="/")
    return response


@router.get("/me")
async def me(request: Request) -> dict:
    return {"username": request.state.session.username}
