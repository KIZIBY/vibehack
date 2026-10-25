"""Формат ошибок Error из contracts/openapi.yaml: {"error": {"code", "message", "request_id", "details"?}}."""
from typing import Any, Optional

from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from .logging import request_id_var

HTTP_CODES = {
    400: "bad_request", 401: "unauthorized", 403: "forbidden", 404: "not_found", 405: "method_not_allowed",
    409: "conflict", 413: "too_large", 422: "invalid", 429: "rate_limited",
    500: "internal", 503: "unavailable",
}
SERVER_ERROR_MESSAGES = {503: "Сервис временно недоступен"}
DEFAULT_SERVER_ERROR_MESSAGE = "Внутренняя ошибка сервера"


def error_response(status: int, code: str, message: str, details: Optional[dict[str, Any]] = None) -> JSONResponse:
    body: dict[str, Any] = {"code": code, "message": message, "request_id": request_id_var.get() or ""}
    if details:
        body["details"] = details
    return JSONResponse({"error": body}, status_code=status)


async def http_exception_handler(request: Request, exc: StarletteHTTPException) -> JSONResponse:
    if exc.status_code >= 500:   # детали серверных ошибок клиенту не отдаём
        message = SERVER_ERROR_MESSAGES.get(exc.status_code, DEFAULT_SERVER_ERROR_MESSAGE)
    else:
        message = exc.detail if isinstance(exc.detail, str) else "Ошибка запроса"
    response = error_response(exc.status_code, HTTP_CODES.get(exc.status_code, "http_error"), message)
    for name, value in (exc.headers or {}).items():
        response.headers[name] = value
    return response


async def validation_exception_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    # поле input из ошибок pydantic не возвращаем: в нём могут быть данные клиента целиком
    errors = [{"loc": [str(part) for part in e["loc"]], "msg": e["msg"], "type": e["type"]} for e in exc.errors()]
    return error_response(422, "invalid", "Неверные данные запроса", {"errors": errors})


def internal_error_response() -> JSONResponse:
    return error_response(500, "internal", DEFAULT_SERVER_ERROR_MESSAGE)
