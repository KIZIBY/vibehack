"""Структурные JSON-логи: одна строка на запись, request_id из contextvar."""
import json
import logging as stdlib_logging
import sys
from contextvars import ContextVar
from datetime import datetime, timezone
from typing import Optional, TextIO

request_id_var: ContextVar[Optional[str]] = ContextVar("request_id", default=None)

_STANDARD_ATTRS = frozenset(stdlib_logging.LogRecord("", 0, "", 0, "", (), None).__dict__) | {"message", "asctime", "taskName"}
_HANDLER_MARK = "_judge_json_handler"


class JsonFormatter(stdlib_logging.Formatter):
    def format(self, record: stdlib_logging.LogRecord) -> str:
        payload = {
            "ts": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "request_id": request_id_var.get(),
        }
        for key, value in record.__dict__.items():
            if key not in _STANDARD_ATTRS and key not in payload:
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False, default=str)


def configure_logging(level: str = "INFO", stream: Optional[TextIO] = None) -> None:
    """Подключает JSON-обработчик к корневому логгеру; повторный вызов заменяет прежний, а не дублирует."""
    root = stdlib_logging.getLogger()
    for handler in [h for h in root.handlers if getattr(h, _HANDLER_MARK, False)]:
        root.removeHandler(handler)
    handler = stdlib_logging.StreamHandler(stream if stream is not None else sys.stdout)
    handler.setFormatter(JsonFormatter())
    setattr(handler, _HANDLER_MARK, True)
    root.addHandler(handler)
    root.setLevel(level.upper())
    # собственный access-лог приложения заменяет uvicorn.access: иначе каждый запрос пишется дважды
    access = stdlib_logging.getLogger("uvicorn.access")
    access.handlers.clear()
    access.propagate = False
