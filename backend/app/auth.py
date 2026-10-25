"""Вход общим демо-аккаунтом: подписанный токен сессии, лимит попыток, защита маршрутов /api/*."""
import base64
import hmac
import json
import logging
import math
import secrets
import time
from collections import deque
from dataclasses import dataclass
from typing import Callable, Optional

from starlette.datastructures import Headers

from .errors import error_response

SESSION_COOKIE = "session"
SESSION_TTL = 12 * 3600
LOGIN_PATH = "/api/v1/auth/login"
LOGOUT_PATH = "/api/v1/auth/logout"
API_PREFIX = "/api/"
LOGIN_ATTEMPTS = 5
LOGIN_WINDOW = 60.0
MAX_TOKEN_LENGTH = 1024
MAX_TRACKED_CLIENTS = 10000

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class Session:
    username: str
    jti: str
    exp: float


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


class SessionManager:
    """Токен: base64(payload).base64(HMAC-SHA256). Без секрета токены не выдаются и не принимаются."""

    def __init__(self, secret: Optional[str], clock: Callable[[], float] = time.time):
        self._secret = secret.encode() if secret else None
        self._clock = clock
        self._revoked: dict[str, float] = {}

    @property
    def configured(self) -> bool:
        return self._secret is not None

    def _sign(self, payload_b64: str) -> str:
        return _b64(hmac.new(self._secret, payload_b64.encode("ascii"), "sha256").digest())

    def issue(self, username: str, jti: Optional[str] = None) -> str:
        if self._secret is None:
            raise RuntimeError("session_secret не задан")
        payload = {"u": username, "jti": jti or secrets.token_hex(16), "exp": self._clock() + SESSION_TTL}
        payload_b64 = _b64(json.dumps(payload, separators=(",", ":")).encode())
        return f"{payload_b64}.{self._sign(payload_b64)}"

    def verify(self, token: Optional[str]) -> Optional[Session]:
        if not token or self._secret is None or len(token) > MAX_TOKEN_LENGTH or not token.isascii():
            return None
        if token.count(".") != 1:
            return None
        payload_b64, signature = token.split(".")
        if not hmac.compare_digest(signature.encode(), self._sign(payload_b64).encode()):
            return None
        try:
            payload = json.loads(_unb64(payload_b64))
            session = Session(str(payload["u"]), str(payload["jti"]), float(payload["exp"]))
        except (ValueError, KeyError, TypeError):
            return None
        now = self._clock()
        if session.exp <= now or session.jti in self._revoked:
            return None
        return session

    def revoke(self, session: Session) -> None:
        now = self._clock()
        self._revoked = {jti: exp for jti, exp in self._revoked.items() if exp > now}
        self._revoked[session.jti] = session.exp


class LoginLimiter:
    """Скользящее окно: не больше LOGIN_ATTEMPTS попыток за LOGIN_WINDOW секунд с одного адреса."""

    def __init__(self, clock: Callable[[], float] = time.time, max_clients: int = MAX_TRACKED_CLIENTS):
        self._clock = clock
        self._max_clients = max_clients
        self._attempts: dict[str, deque] = {}

    def tracked_clients(self) -> int:
        return len(self._attempts)

    def _forget_stale(self, now: float) -> None:
        for client in [c for c, window in self._attempts.items() if not window or now - window[-1] >= LOGIN_WINDOW]:
            del self._attempts[client]
        while len(self._attempts) >= self._max_clients:
            del self._attempts[next(iter(self._attempts))]   # самый давний адрес: словарь хранит порядок вставки

    def register(self, client: str) -> Optional[int]:
        """Учитывает попытку; None — можно, иначе число секунд до освобождения окна."""
        now = self._clock()
        if client not in self._attempts:
            self._forget_stale(now)
        window = self._attempts.setdefault(client, deque())
        while window and now - window[0] >= LOGIN_WINDOW:
            window.popleft()
        if len(window) >= LOGIN_ATTEMPTS:
            return max(1, math.ceil(window[0] + LOGIN_WINDOW - now))
        window.append(now)
        return None


def credentials_match(expected_user: str, expected_password: str, user: str, password: str) -> bool:
    """Обе проверки выполняются всегда и за постоянное время: по времени ответа не отличить, что неверно."""
    user_ok = hmac.compare_digest(user.encode(), expected_user.encode())
    password_ok = hmac.compare_digest(password.encode(), expected_password.encode())
    return user_ok and password_ok


def session_cookie(token: str, *, secure: bool) -> str:
    parts = [f"{SESSION_COOKIE}={token}", "HttpOnly", f"Max-Age={SESSION_TTL}", "Path=/", "SameSite=lax"]
    if secure:
        parts.append("Secure")
    return "; ".join(parts)


class AuthMiddleware:
    """Любой путь /api/* кроме входа требует сессию; ответы продлевают её (скользящее окно)."""

    def __init__(self, app, sessions_of: Callable[[], SessionManager], secure_of: Callable[[], bool]):
        self.app = app
        self._sessions_of = sessions_of
        self._secure_of = secure_of

    async def __call__(self, scope, receive, send):
        path = scope.get("path", "")
        if scope["type"] != "http" or not path.startswith(API_PREFIX) or (
            scope["method"] == "POST" and path == LOGIN_PATH
        ):
            await self.app(scope, receive, send)
            return
        sessions = self._sessions_of()
        token = _cookie_value(Headers(scope=scope).get("cookie", ""), SESSION_COOKIE)
        session = sessions.verify(token)
        if session is None:
            response = error_response(401, "unauthorized", "Требуется вход")
            await response(scope, receive, send)
            return
        scope.setdefault("state", {})["session"] = session
        refresh = path != LOGOUT_PATH

        async def send_refreshed(message):
            if refresh and message["type"] == "http.response.start":
                message.setdefault("headers", [])
                new_token = sessions.issue(session.username, jti=session.jti)
                message["headers"].append(
                    (b"set-cookie", session_cookie(new_token, secure=self._secure_of()).encode("latin-1"))
                )
            await send(message)

        await self.app(scope, receive, send_refreshed)


def _cookie_value(header: str, name: str) -> Optional[str]:
    for chunk in header.split(";"):
        key, _, value = chunk.strip().partition("=")
        if key == name:
            return value
    return None
