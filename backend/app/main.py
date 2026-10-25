"""Фабрика приложения. Запуск: uvicorn app.main:app --app-dir backend."""
import importlib
import pkgutil
from contextlib import asynccontextmanager
from typing import Awaitable, Callable, Optional

from fastapi import APIRouter, FastAPI
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException

from .config import Settings, load_settings
from .errors import http_exception_handler, validation_exception_handler
from .health import router as health_router
from .logging import configure_logging
from .middleware import RequestContextMiddleware


def include_routers(app: FastAPI, package_name: str) -> None:
    """Подключает роутеры всех модулей пакета в алфавитном порядке; ошибка импорта модуля не скрывается."""
    package = importlib.import_module(package_name)
    for module_info in sorted(pkgutil.iter_modules(package.__path__), key=lambda m: m.name):
        module = importlib.import_module(f"{package_name}.{module_info.name}")
        router = getattr(module, "router", None)
        if isinstance(router, APIRouter):
            app.include_router(router)


def create_app(
    settings: Optional[Settings] = None,
    *,
    routers_package: str = "app.routers",
    agent_probe: Optional[Callable[[], Awaitable[str]]] = None,
    agent_probe_timeout: float = 2.0,
) -> FastAPI:
    settings = settings or load_settings()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        configure_logging(settings.log_level)
        yield

    app = FastAPI(title="AI-судья", version=settings.version, lifespan=lifespan)
    app.state.settings = settings
    app.state.agent_probe = agent_probe
    app.state.agent_probe_timeout = agent_probe_timeout
    app.add_exception_handler(StarletteHTTPException, http_exception_handler)
    app.add_exception_handler(RequestValidationError, validation_exception_handler)
    app.add_middleware(RequestContextMiddleware)
    app.include_router(health_router)
    include_routers(app, routers_package)
    return app


app = create_app()
