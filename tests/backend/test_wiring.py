"""Проводка сервисов в приложение: ленивые хранилище, раннер intake, шлюз; обработчики исключений сервисов."""
import textwrap
import uuid

import pytest


def make_pkg(tmp_path, monkeypatch, source):
    name = f"wr_{uuid.uuid4().hex[:10]}"
    pkg = tmp_path / name
    pkg.mkdir()
    (pkg / "__init__.py").write_text("")
    (pkg / "boom.py").write_text(textwrap.dedent(source))
    monkeypatch.syspath_prepend(str(tmp_path))
    return name


def settings(**env):
    from app.config import load_settings
    return load_settings({"JUDGE_VERSION": "w", **env})


# ─────────────── ленивые сервисы ───────────────

def test_get_storage_is_rooted_at_data_dir_and_cached(tmp_path):
    from app.main import create_app
    from app.services.storage import Storage
    from app.state import get_storage
    app = create_app(settings(JUDGE_DATA_DIR=str(tmp_path / "data")))
    first = get_storage(app)
    assert isinstance(first, Storage) and first.root == tmp_path / "data"
    assert get_storage(app) is first


def test_get_storage_respects_override(tmp_path):
    from app.main import create_app
    from app.services.storage import Storage
    from app.state import get_storage
    app = create_app(settings())
    custom = Storage(tmp_path)
    app.state.storage = custom
    assert get_storage(app) is custom


def test_get_intake_runner_default_and_override():
    from app.main import create_app
    from app.services.intake_runner import IntakeRunner
    from app.state import get_intake_runner
    app = create_app(settings())
    runner = get_intake_runner(app)
    assert isinstance(runner, IntakeRunner) and get_intake_runner(app) is runner
    custom = IntakeRunner(command=["true"])
    app.state.intake_runner = custom
    assert get_intake_runner(app) is custom


def test_get_gateway_none_when_not_configured():
    from app.main import create_app
    from app.state import get_gateway
    assert get_gateway(create_app(settings())) is None


def test_get_gateway_builds_hermes_gateway_from_settings_without_leaking_key():
    from app.main import create_app
    from app.services.gateway import HermesGateway
    from app.state import get_gateway
    app = create_app(settings(HERMES_API_URL="http://hermes.internal:8642", API_SERVER_KEY="key-wiring-secret"))
    gateway = get_gateway(app)
    assert isinstance(gateway, HermesGateway) and get_gateway(app) is gateway
    assert "hermes.internal" in repr(gateway) and "key-wiring-secret" not in repr(gateway)


def test_get_gateway_respects_override():
    from app.main import create_app
    from app.services.gateway import FakeAgentGateway
    from app.state import get_gateway
    app = create_app(settings(HERMES_API_URL="http://hermes.internal:8642", API_SERVER_KEY="k"))
    fake = FakeAgentGateway("/tmp/unused")
    app.state.gateway = fake
    assert get_gateway(app) is fake


def test_health_uses_gateway_probe_when_no_explicit_probe(tmp_path):
    from fastapi.testclient import TestClient
    from app.main import create_app
    from app.services.gateway import FakeAgentGateway
    app = create_app(settings())
    app.state.gateway = FakeAgentGateway(tmp_path, probe_state="down")
    assert TestClient(app).get("/health").json()["agents"] == "down"
    app.state.gateway = FakeAgentGateway(tmp_path, probe_state="up")
    assert TestClient(app).get("/health").json()["agents"] == "up"


# ─────────────── обработчики исключений сервисов ───────────────

SOURCES = {
    "payload": ("from fastapi import APIRouter\nfrom app.services.storage import PayloadTooLarge\nrouter = APIRouter()\n"
                "@router.get('/x')\ndef x():\n    raise PayloadTooLarge('too big: secret-path-fragment')\n"),
    "unsafe_path": ("from fastapi import APIRouter\nfrom app.services.storage import UnsafePath\nrouter = APIRouter()\n"
                    "@router.get('/x')\ndef x():\n    raise UnsafePath('/etc/passwd escape')\n"),
    "exists": ("from fastapi import APIRouter\nrouter = APIRouter()\n"
               "@router.get('/x')\ndef x():\n    raise FileExistsError('/srv/data/projects/p/briefs/m/f.txt')\n"),
    "unsafe_url": ("from fastapi import APIRouter\nfrom app.services.netguard import UnsafeUrl\nrouter = APIRouter()\n"
                   "@router.get('/x')\ndef x():\n    raise UnsafeUrl('http://127.0.0.1/ private')\n"),
}


@pytest.mark.parametrize("key,status,code", [
    ("payload", 413, "too_large"), ("unsafe_path", 400, "bad_request"),
    ("exists", 409, "conflict"), ("unsafe_url", 422, "invalid"),
])
def test_service_exceptions_map_to_error_format(tmp_path, monkeypatch, key, status, code):
    from fastapi.testclient import TestClient
    from app.main import create_app
    app = create_app(settings(), routers_package=make_pkg(tmp_path, monkeypatch, SOURCES[key]))
    resp = TestClient(app, raise_server_exceptions=False).get("/x")
    assert resp.status_code == status, resp.text
    error = resp.json()["error"]
    assert error["code"] == code and error["request_id"] == resp.headers["X-Request-ID"]
    for leaked in ("secret-path-fragment", "/etc/passwd", "/srv/data", "127.0.0.1"):
        assert leaked not in resp.text, f"в ответе утекло {leaked!r}"
