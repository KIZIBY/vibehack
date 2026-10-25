"""Сквозной контекст запроса: X-Request-ID, access-лог, перехват необработанных исключений."""
import logging
import re
import time
import uuid

from starlette.datastructures import Headers, MutableHeaders

from .errors import internal_error_response
from .logging import request_id_var

REQUEST_ID_HEADER = "X-Request-ID"
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
access_log = logging.getLogger("app.access")
error_log = logging.getLogger("app.errors")


def pick_request_id(incoming):
    """Входящий идентификатор берём только в безопасном формате, иначе выдаём свой."""
    if incoming and REQUEST_ID_RE.fullmatch(incoming):
        return incoming
    return uuid.uuid4().hex


class RequestContextMiddleware:
    """ASGI-middleware без BaseHTTPMiddleware: contextvar и исключения проходят сквозь него без потерь."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        request_id = pick_request_id(Headers(scope=scope).get(REQUEST_ID_HEADER))
        token = request_id_var.set(request_id)
        started = False
        aborted = False
        status = 500
        began = time.perf_counter()

        async def send_with_id(message):
            nonlocal started, status
            if message["type"] == "http.response.start":
                started = True
                status = message["status"]
                message.setdefault("headers", [])
                MutableHeaders(scope=message)[REQUEST_ID_HEADER] = request_id
            await send(message)

        try:
            try:
                await self.app(scope, receive, send_with_id)
            except Exception:
                error_log.error("необработанное исключение", exc_info=True)
                if started:   # ответ уже пошёл клиенту: статус не переписать, помечаем обрыв
                    aborted = True
                    raise
                status = 500
                await internal_error_response()(scope, receive, send_with_id)
        finally:
            access_log.info(
                "%s %s %s", scope["method"], scope["path"], status,
                extra={"method": scope["method"], "path": scope["path"], "status": status,
                       "duration_ms": round((time.perf_counter() - began) * 1000, 2), "aborted": aborted},
            )
            request_id_var.reset(token)
