"""Ленивая сборка сервисов приложения: объект можно подменить через app.state (тесты, оркестратор)."""
from typing import Optional

from fastapi import FastAPI

from .services.gateway import AgentGateway, HermesGateway
from .services.intake_runner import IntakeRunner
from .services.storage import Storage


def get_storage(app: FastAPI) -> Storage:
    if getattr(app.state, "storage", None) is None:
        app.state.storage = Storage(app.state.settings.data_dir)
    return app.state.storage


def get_intake_runner(app: FastAPI) -> IntakeRunner:
    if getattr(app.state, "intake_runner", None) is None:
        app.state.intake_runner = IntakeRunner()
    return app.state.intake_runner


def get_gateway(app: FastAPI) -> Optional[AgentGateway]:
    """Шлюз агентов: подмена в app.state.gateway, иначе HermesGateway по HERMES_API_URL, иначе None."""
    if getattr(app.state, "gateway", None) is None:
        settings = app.state.settings
        if not settings.hermes_api_url:
            return None
        app.state.gateway = HermesGateway(settings.hermes_api_url, settings.api_server_key or "")
    return app.state.gateway
