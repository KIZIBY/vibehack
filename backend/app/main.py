"""Фабрика приложения. Запуск: uvicorn app.main:app --app-dir backend."""
import asyncio
import importlib
import logging
import pkgutil
import time
from contextlib import asynccontextmanager
from typing import Awaitable, Callable, Optional

from fastapi import APIRouter, FastAPI
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException

from .auth import AuthMiddleware, LoginLimiter, SessionManager
from .config import Settings, load_settings
from .db import make_engine, make_session_factory
from .errors import (
    file_exists_handler, http_exception_handler, payload_too_large_handler, unsafe_path_handler,
    rubric_not_confirmed_handler, unsafe_url_handler, validation_exception_handler, version_conflict_handler,
)
from .health import router as health_router
from .logging import configure_logging
from .middleware import RequestContextMiddleware
from .repositories.base import VersionConflict
from .services import recovery
from .services.netguard import UnsafeUrl
from .services.rubric import RubricNotConfirmed
from .services.storage import PayloadTooLarge, UnsafePath


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
    clock: Callable[[], float] = time.time,
) -> FastAPI:
    settings = settings or load_settings()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        configure_logging(settings.log_level)
        try:
            await asyncio.to_thread(recovery.recover_interrupted_work, app.state.session_factory)
        except Exception:
            logging.getLogger(__name__).error("восстановление прерванной работы не удалось", exc_info=True)
        yield
        app.state.engine.dispose()

    app = FastAPI(title="AI-судья", version=settings.version, lifespan=lifespan)
    app.state.settings = settings
    app.state.agent_probe = agent_probe
    app.state.agent_probe_timeout = agent_probe_timeout
    app.state.engine = make_engine(settings.database_url)
    app.state.session_factory = make_session_factory(app.state.engine)
    app.state.sessions = SessionManager(settings.session_secret, clock)
    app.state.login_limiter = LoginLimiter(clock)
    app.add_exception_handler(StarletteHTTPException, http_exception_handler)
    app.add_exception_handler(RequestValidationError, validation_exception_handler)
    app.add_exception_handler(VersionConflict, version_conflict_handler)
    app.add_exception_handler(PayloadTooLarge, payload_too_large_handler)
    app.add_exception_handler(UnsafePath, unsafe_path_handler)
    app.add_exception_handler(FileExistsError, file_exists_handler)
    app.add_exception_handler(UnsafeUrl, unsafe_url_handler)
    app.add_exception_handler(RubricNotConfirmed, rubric_not_confirmed_handler)
    app.add_middleware(AuthMiddleware, sessions_of=lambda: app.state.sessions, secure_of=lambda: settings.cookie_secure)
    app.add_middleware(RequestContextMiddleware)
    app.include_router(health_router)
    include_routers(app, routers_package)
    return app


app = create_app()
