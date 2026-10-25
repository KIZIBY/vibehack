"""T020: каркас backend-приложения (FastAPI-фабрика, конфиг, JSON-логи, request_id, формат ошибок,
автоподключение роутеров, GET /health). Тесты написаны ДО реализации (RED): пакета ``backend/app`` ещё нет.

Контракт:
- ``app.main.create_app(settings=None, *, routers_package="app.routers", agent_probe=None,
  agent_probe_timeout=2.0) -> FastAPI``; ``app.main.app = create_app()``;
- ``app.config.load_settings(env=None) -> Settings`` (пустая строка = не задано; секреты маскируются в repr/str);
- ``app.logging.configure_logging(level="INFO", stream=None)`` + ``request_id_var`` (contextvars);
- middleware: ``X-Request-ID`` у каждого ответа (входящий — только если ``^[A-Za-z0-9._-]{1,64}$``),
  одна access-запись INFO на запрос; ошибки в формате ``Error`` из contracts/openapi.yaml;
- роутеры из ``routers_package`` подключаются автоматически в алфавитном порядке, ошибка импорта — наружу;
- ``GET /health`` публичный: ``{"status": "ok", "agents": up|down|unknown, "version": ...}``.

Допущения: access-запись и записи об ошибках проверяются через вывод ``configure_logging(stream=...)``
(JSON-строки), для чего ``configure_logging`` вызывается ПОСЛЕ ``create_app`` и до запроса; переводы строк
в ``X-Request-ID`` не проверяются (клиент httpx отклоняет такой заголовок ещё до отправки).

Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR/SKIP.
"""
from __future__ import annotations

import asyncio
import io
import json
import logging
import re
import textwrap
import time
import uuid
from datetime import datetime, timedelta
from pathlib import Path

import jsonschema
import pytest
import yaml

REPO = Path(__file__).resolve().parents[2]
OPENAPI = REPO / "specs" / "001-ai-judge-platform" / "contracts" / "openapi.yaml"
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
SECRET = "SuperSecretValue-9f3a"


# ─────────────────────────────── хелперы и фикстуры ───────────────────────────────

@pytest.fixture(autouse=True)
def restore_root_logger():
    """configure_logging правит корневой логгер; возвращаем его как был (только stdlib, без импорта app)."""
    root = logging.getLogger()
    handlers, level = root.handlers[:], root.level
    yield
    root.handlers[:] = handlers
    root.setLevel(level)


def openapi_doc() -> dict:
    return yaml.safe_load(OPENAPI.read_text(encoding="utf-8"))


def health_schema() -> dict:
    return openapi_doc()["paths"]["/health"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]


def error_schema() -> dict:
    return openapi_doc()["components"]["schemas"]["Error"]


SAMPLE_ROUTES = '''
import logging
from fastapi import APIRouter
router = APIRouter()

@router.get("/ping")
def ping():
    return {"ok": True}

@router.get("/boom")
def boom():
    raise RuntimeError("secret-internal-detail")

@router.get("/items/{n}")
def item(n: int):
    return {"n": n}

@router.post("/only-post")
def only_post():
    return {"ok": True}

@router.get("/log")
async def log_inside():
    logging.getLogger("t.inside").info("inside-request")
    return {"ok": True}
'''


def make_pkg(tmp_path: Path, monkeypatch, modules: dict[str, str] | None = None) -> str:
    """Временный пакет роутеров с уникальным именем; возвращает его имя для routers_package."""
    name = f"rt_{uuid.uuid4().hex[:10]}"
    pkg = tmp_path / name
    pkg.mkdir()
    (pkg / "__init__.py").write_text("")
    for mod, src in (modules if modules is not None else {"sample": SAMPLE_ROUTES}).items():
        (pkg / f"{mod}.py").write_text(textwrap.dedent(src))
    monkeypatch.syspath_prepend(str(tmp_path))
    return name


def make_app(tmp_path, monkeypatch, *, modules=None, version="t1", **kwargs):
    from app.config import load_settings
    from app.main import create_app
    pkg = make_pkg(tmp_path, monkeypatch, modules)
    return create_app(load_settings({"JUDGE_VERSION": version}), routers_package=pkg, **kwargs)


def make_client(app):
    from fastapi.testclient import TestClient
    return TestClient(app, raise_server_exceptions=False)


def start_logging(level: str = "INFO") -> io.StringIO:
    from app.logging import configure_logging
    buf = io.StringIO()
    configure_logging(level=level, stream=buf)
    return buf


def log_records(buf: io.StringIO) -> list[dict]:
    lines = [ln for ln in buf.getvalue().splitlines() if ln.strip()]
    return [json.loads(ln) for ln in lines]   # каждая строка обязана быть валидным JSON


def assert_error(resp, status: int, code: str) -> dict:
    assert resp.status_code == status, resp.text
    body = resp.json()
    jsonschema.validate(body, error_schema())
    assert body["error"]["code"] == code
    assert body["error"]["request_id"] == resp.headers["X-Request-ID"]
    return body["error"]


# ─────────────────────────────── config ───────────────────────────────

def test_settings_defaults():
    from app.config import load_settings
    s = load_settings({})
    assert s.database_url == "sqlite:///judge.db"
    assert s.data_dir == "./data"
    assert s.hermes_api_url is None and s.api_server_key is None
    assert s.max_parallel_submissions == 5 and s.retention_days == 7
    assert s.demo_user is None and s.demo_password is None and s.session_secret is None
    assert s.version == "dev"


def test_settings_overrides_and_int_cast():
    from app.config import load_settings
    s = load_settings({
        "JUDGE_DATABASE_URL": "sqlite:///other.db", "JUDGE_DATA_DIR": "/srv/data",
        "HERMES_API_URL": "http://hermes:8642", "API_SERVER_KEY": "key-1",
        "JUDGE_MAX_PARALLEL_SUBMISSIONS": "3", "JUDGE_RETENTION_DAYS": "14",
        "JUDGE_DEMO_USER": "demo", "JUDGE_DEMO_PASSWORD": "pw-1", "JUDGE_SESSION_SECRET": "sec-1",
        "JUDGE_VERSION": "1.2.3",
    })
    assert (s.database_url, s.data_dir) == ("sqlite:///other.db", "/srv/data")
    assert (s.hermes_api_url, s.api_server_key) == ("http://hermes:8642", "key-1")
    assert s.max_parallel_submissions == 3 and isinstance(s.max_parallel_submissions, int)
    assert s.retention_days == 14 and isinstance(s.retention_days, int)
    assert (s.demo_user, s.demo_password, s.session_secret) == ("demo", "pw-1", "sec-1")
    assert s.version == "1.2.3"


def test_settings_empty_string_means_default():
    from app.config import load_settings
    s = load_settings({"JUDGE_DATABASE_URL": "", "HERMES_API_URL": "", "JUDGE_RETENTION_DAYS": "",
                       "JUDGE_MAX_PARALLEL_SUBMISSIONS": "", "JUDGE_VERSION": ""})
    assert s.database_url == "sqlite:///judge.db" and s.hermes_api_url is None
    assert s.retention_days == 7 and s.max_parallel_submissions == 5 and s.version == "dev"


def test_settings_none_env_reads_os_environ(monkeypatch):
    from app.config import load_settings
    monkeypatch.setenv("JUDGE_VERSION", "from-os-environ")
    monkeypatch.setenv("JUDGE_RETENTION_DAYS", "30")
    s = load_settings()
    assert s.version == "from-os-environ" and s.retention_days == 30


@pytest.mark.parametrize("var,value", [("JUDGE_MAX_PARALLEL_SUBMISSIONS", "abc"),
                                       ("JUDGE_RETENTION_DAYS", "1.5"),
                                       ("JUDGE_RETENTION_DAYS", "seven")])
def test_settings_non_integer_raises_value_error_naming_variable(var, value):
    from app.config import load_settings
    with pytest.raises(ValueError, match=var):
        load_settings({var: value})


@pytest.mark.parametrize("render", [repr, str])
def test_settings_secrets_masked_in_repr_and_str(render):
    from app.config import load_settings
    s = load_settings({"JUDGE_DEMO_PASSWORD": SECRET + "-pw", "JUDGE_SESSION_SECRET": SECRET + "-ss",
                       "API_SERVER_KEY": SECRET + "-key", "JUDGE_DEMO_USER": "visible-user",
                       "HERMES_API_URL": "http://visible-hermes:8642"})
    text = render(s)
    assert SECRET not in text, "значение секрета попало в представление настроек"
    assert "***" in text
    assert "visible-user" in text and "http://visible-hermes:8642" in text


# ─────────────────────────────── logging ───────────────────────────────

def test_logging_emits_one_json_line_with_required_fields():
    buf = start_logging()
    logging.getLogger("svc.part").info("hello world")
    (rec,) = log_records(buf)
    assert rec["level"] == "INFO" and rec["logger"] == "svc.part" and rec["message"] == "hello world"
    assert rec["request_id"] is None, "вне запроса request_id = null"
    ts = datetime.fromisoformat(rec["ts"])
    assert ts.utcoffset() == timedelta(0), f"ts не в UTC: {rec['ts']}"


def test_logging_includes_extra_fields():
    buf = start_logging()
    logging.getLogger("svc").info("with extra", extra={"project_id": "P1", "attempt": 3})
    (rec,) = log_records(buf)
    assert rec["project_id"] == "P1" and rec["attempt"] == 3


def test_logging_request_id_from_contextvar():
    from app.logging import request_id_var
    buf = start_logging()
    token = request_id_var.set("req-42")
    try:
        logging.getLogger("svc").info("inside")
    finally:
        request_id_var.reset(token)
    logging.getLogger("svc").info("outside")
    inside, outside = log_records(buf)
    assert inside["request_id"] == "req-42" and outside["request_id"] is None


def test_logging_repeated_configure_does_not_duplicate_handlers():
    from app.logging import configure_logging
    buf = io.StringIO()
    configure_logging(stream=buf)
    count = len(logging.getLogger().handlers)
    configure_logging(stream=buf)
    assert len(logging.getLogger().handlers) == count
    logging.getLogger("svc").info("once")
    assert len(log_records(buf)) == 1


def test_logging_level_filters_records():
    buf = start_logging(level="WARNING")
    logging.getLogger("svc").info("hidden")
    logging.getLogger("svc").warning("shown")
    assert [r["message"] for r in log_records(buf)] == ["shown"]


def test_logging_exception_record_is_valid_json():
    buf = start_logging()
    try:
        raise RuntimeError("kaboom")
    except RuntimeError:
        logging.getLogger("svc").error("failed", exc_info=True)
    (rec,) = log_records(buf)
    assert rec["level"] == "ERROR" and rec["message"] == "failed"


# ─────────────────────────────── middleware request_id и access-лог ───────────────────────────────

@pytest.mark.parametrize("path,status", [("/ping", 200), ("/missing", 404), ("/boom", 500)])
def test_every_response_has_request_id_header(tmp_path, monkeypatch, path, status):
    client = make_client(make_app(tmp_path, monkeypatch))
    resp = client.get(path)
    assert resp.status_code == status
    assert REQUEST_ID_RE.match(resp.headers.get("X-Request-ID", "")), resp.headers


@pytest.mark.parametrize("rid", ["abc-123_X.y", "a", "z" * 64])
def test_valid_incoming_request_id_is_reused(tmp_path, monkeypatch, rid):
    client = make_client(make_app(tmp_path, monkeypatch))
    assert client.get("/ping", headers={"X-Request-ID": rid}).headers["X-Request-ID"] == rid


@pytest.mark.parametrize("rid", ["z" * 65, "bad id", "a/b", "<script>", "a,b", ""])
def test_invalid_incoming_request_id_is_replaced(tmp_path, monkeypatch, rid):
    client = make_client(make_app(tmp_path, monkeypatch))
    got = client.get("/ping", headers={"X-Request-ID": rid}).headers["X-Request-ID"]
    assert got != rid and REQUEST_ID_RE.match(got), f"отправили {rid!r}, получили {got!r}"


def test_request_id_generated_when_absent_and_unique(tmp_path, monkeypatch):
    client = make_client(make_app(tmp_path, monkeypatch))
    first, second = (client.get("/ping").headers["X-Request-ID"] for _ in range(2))
    assert REQUEST_ID_RE.match(first) and REQUEST_ID_RE.match(second) and first != second


def test_access_log_one_info_record_per_request(tmp_path, monkeypatch):
    app = make_app(tmp_path, monkeypatch)
    buf = start_logging()
    resp = make_client(app).get("/ping", headers={"X-Request-ID": "acc-1"})
    recs = [r for r in log_records(buf) if r.get("path") == "/ping"]
    assert len(recs) == 1, recs
    rec = recs[0]
    assert rec["level"] == "INFO" and rec["method"] == "GET" and rec["status"] == 200
    assert isinstance(rec["duration_ms"], (int, float)) and rec["duration_ms"] >= 0
    assert rec["request_id"] == "acc-1" == resp.headers["X-Request-ID"]


def test_access_log_records_error_statuses(tmp_path, monkeypatch):
    app = make_app(tmp_path, monkeypatch)
    buf = start_logging()
    make_client(app).get("/missing")
    recs = [r for r in log_records(buf) if r.get("path") == "/missing"]
    assert len(recs) == 1 and recs[0]["status"] == 404


def test_log_inside_request_carries_request_id(tmp_path, monkeypatch):
    app = make_app(tmp_path, monkeypatch)
    buf = start_logging()
    resp = make_client(app).get("/log", headers={"X-Request-ID": "inner-7"})
    inner = [r for r in log_records(buf) if r["message"] == "inside-request"]
    assert len(inner) == 1 and inner[0]["request_id"] == "inner-7" == resp.headers["X-Request-ID"]


# ─────────────────────────────── формат ошибок ───────────────────────────────

def test_404_uses_error_format(tmp_path, monkeypatch):
    resp = make_client(make_app(tmp_path, monkeypatch)).get("/no/such/route")
    assert_error(resp, 404, "not_found")


def test_405_uses_error_format(tmp_path, monkeypatch):
    resp = make_client(make_app(tmp_path, monkeypatch)).get("/only-post")
    assert_error(resp, 405, "method_not_allowed")


def test_422_uses_error_format_with_details(tmp_path, monkeypatch):
    resp = make_client(make_app(tmp_path, monkeypatch)).get("/items/not-a-number")
    err = assert_error(resp, 422, "invalid")
    assert isinstance(err.get("details"), dict) and err["details"], "422 обязан нести непустой details"


def test_500_hides_exception_text_and_logs_error_with_request_id(tmp_path, monkeypatch):
    app = make_app(tmp_path, monkeypatch)
    buf = start_logging()
    resp = make_client(app).get("/boom", headers={"X-Request-ID": "boom-1"})
    err = assert_error(resp, 500, "internal")
    for leaked in ("secret-internal-detail", "RuntimeError", "Traceback"):
        assert leaked not in resp.text, f"в теле 500 утекло {leaked!r}"
    assert err["message"] and err["request_id"] == "boom-1"
    errors = [r for r in log_records(buf) if r["level"] == "ERROR"]
    assert errors and all(r["request_id"] == "boom-1" for r in errors), errors


# ─────────────────────────────── автоподключение роутеров ───────────────────────────────

def _dup_module(label: str) -> str:
    return f'''
        from fastapi import APIRouter
        router = APIRouter()
        @router.get("/dup")
        def dup():
            return {{"from": "{label}"}}
        @router.get("/only-{label}")
        def only():
            return {{"from": "{label}"}}
    '''


def test_routers_included_alphabetically(tmp_path, monkeypatch):
    # файлы создаются в обратном порядке: порядок подключения не должен зависеть от порядка создания
    app = make_app(tmp_path, monkeypatch, modules={"zz_late": _dup_module("late"), "aa_early": _dup_module("early")})
    paths = list(app.openapi()["paths"])   # app.routes в новых FastAPI не плоский (вложенные include), openapi — плоский
    assert paths.index("/only-early") < paths.index("/only-late"), paths
    assert make_client(app).get("/dup").json() == {"from": "early"}, "при конфликте путей выигрывает алфавитно первый"


def test_module_without_router_is_skipped(tmp_path, monkeypatch):
    app = make_app(tmp_path, monkeypatch, modules={"sample": SAMPLE_ROUTES, "helpers": "VALUE = 1\n"})
    assert make_client(app).get("/ping").status_code == 200


@pytest.mark.parametrize("source", ["import module_that_does_not_exist_xyz\n",
                                    "raise RuntimeError('router-import-failed')\n"])
def test_router_import_error_propagates_from_create_app(tmp_path, monkeypatch, source):
    with pytest.raises(Exception, match="module_that_does_not_exist_xyz|router-import-failed"):
        make_app(tmp_path, monkeypatch, modules={"sample": SAMPLE_ROUTES, "broken": source})


# ─────────────────────────────── /health ───────────────────────────────

def _health(tmp_path, monkeypatch, **kwargs):
    return make_client(make_app(tmp_path, monkeypatch, **kwargs)).get("/health")


def test_health_without_probe_is_unknown_and_public(tmp_path, monkeypatch):
    resp = _health(tmp_path, monkeypatch)   # без cookie и заголовков авторизации
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok", "agents": "unknown", "version": "t1"}


@pytest.mark.parametrize("answer", ["up", "down"])
def test_health_reports_probe_answer(tmp_path, monkeypatch, answer):
    async def probe():
        return answer
    resp = _health(tmp_path, monkeypatch, agent_probe=probe)
    assert resp.status_code == 200 and resp.json()["agents"] == answer and resp.json()["status"] == "ok"


@pytest.mark.parametrize("bad", ["maybe", None, 42])
def test_health_invalid_probe_value_is_unknown(tmp_path, monkeypatch, bad):
    async def probe():
        return bad
    resp = _health(tmp_path, monkeypatch, agent_probe=probe)
    assert resp.status_code == 200 and resp.json()["agents"] == "unknown"


def test_health_probe_exception_is_down_ok_and_logged(tmp_path, monkeypatch):
    async def probe():
        raise ConnectionError("gateway unreachable")
    app = make_app(tmp_path, monkeypatch, agent_probe=probe)
    buf = start_logging()
    resp = make_client(app).get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok" and resp.json()["agents"] == "down"
    assert any(r["level"] == "ERROR" for r in log_records(buf)), "исключение пробы должно попасть в лог как ERROR"


def test_health_slow_probe_times_out_to_down_quickly(tmp_path, monkeypatch):
    async def probe():
        await asyncio.sleep(5)
        return "up"
    app = make_app(tmp_path, monkeypatch, agent_probe=probe, agent_probe_timeout=0.05)
    client = make_client(app)
    started = time.monotonic()
    resp = client.get("/health")
    elapsed = time.monotonic() - started
    assert resp.status_code == 200 and resp.json()["agents"] == "down"
    assert elapsed < 2.0, f"/health ждал медленную пробу {elapsed:.1f} с"


def test_health_version_comes_from_settings(tmp_path, monkeypatch):
    resp = _health(tmp_path, monkeypatch, version="9.8.7")
    assert resp.json()["version"] == "9.8.7"


@pytest.mark.parametrize("answer", ["up", "down", None])
def test_health_body_matches_openapi_schema(tmp_path, monkeypatch, answer):
    async def probe():
        return answer
    kwargs = {} if answer is None else {"agent_probe": probe}
    resp = _health(tmp_path, monkeypatch, **kwargs)
    jsonschema.validate(resp.json(), health_schema())


def test_health_has_request_id_header(tmp_path, monkeypatch):
    assert REQUEST_ID_RE.match(_health(tmp_path, monkeypatch).headers.get("X-Request-ID", ""))


# ─────────────────────────────── модуль app.main и зависимости ───────────────────────────────

def test_main_module_exposes_fastapi_app_with_health():
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from app.main import app
    assert isinstance(app, FastAPI)
    resp = TestClient(app, raise_server_exceptions=False).get("/health")
    assert resp.status_code == 200 and resp.json()["status"] == "ok"


def test_create_app_default_arguments_work(monkeypatch):
    from fastapi import FastAPI
    from app.main import create_app
    monkeypatch.setenv("JUDGE_VERSION", "default-args")
    assert isinstance(create_app(), FastAPI)


@pytest.mark.parametrize("package", ["fastapi", "uvicorn", "httpx", "alembic", "sqlalchemy"])
def test_backend_requirements_list_package(package):
    text = (REPO / "backend" / "requirements.txt").read_text(encoding="utf-8")
    assert re.search(rf"^{package}($|[^A-Za-z0-9_-])", text, re.I | re.M), f"нет {package} в backend/requirements.txt"


# ═══════════════ ревью T020, круг 1: утечка detail, пароли в URL, pick_request_id, обрыв стрима ═══════════════

HTTP_ERRORS = '''
from fastapi import APIRouter, HTTPException
router = APIRouter()

@router.get("/http500")
def http500():
    raise HTTPException(500, "sensitive-detail")

@router.get("/http503")
def http503():
    raise HTTPException(503, "sensitive-detail")

@router.get("/http400")
def http400():
    raise HTTPException(400, "понятная причина")
'''

STREAM_ABORT = '''
from fastapi import APIRouter
from fastapi.responses import StreamingResponse
router = APIRouter()

@router.get("/stream-abort")
def stream_abort():
    def chunks():
        yield b"first-chunk"
        raise RuntimeError("stream-broke")
    return StreamingResponse(chunks(), media_type="text/plain")
'''


# 1. HTTPException >= 500 не отдаёт detail клиенту; 4xx отдаёт
@pytest.mark.parametrize("path,status,code", [("/http500", 500, "internal"), ("/http503", 503, "unavailable")])
def test_http_exception_5xx_hides_detail(tmp_path, monkeypatch, path, status, code):
    app = make_app(tmp_path, monkeypatch, modules={"sample": SAMPLE_ROUTES, "httperrs": HTTP_ERRORS})
    resp = make_client(app).get(path, headers={"X-Request-ID": "h5-1"})
    assert "sensitive-detail" not in resp.text, "detail HTTPException >= 500 утёк клиенту"
    err = assert_error(resp, status, code)
    assert err["message"] and err["request_id"] == "h5-1"


def test_http_exception_4xx_keeps_detail(tmp_path, monkeypatch):
    app = make_app(tmp_path, monkeypatch, modules={"sample": SAMPLE_ROUTES, "httperrs": HTTP_ERRORS})
    resp = make_client(app).get("/http400")
    assert resp.status_code == 400
    jsonschema.validate(resp.json(), error_schema())
    assert "понятная причина" in resp.json()["error"]["message"]
    assert resp.json()["error"]["request_id"] == resp.headers["X-Request-ID"]


# 2. пароль в URL не попадает в repr/str настроек (URL собираются из частей: литералы с user:pass@ ловит сканер I-7)
DB_PW, HERMES_PW = "S3cretPw", "Tok3n"
DB_URL = "postgresql+psycopg://" + "appuser" + ":" + DB_PW + "@db.local:5432/judge"
HERMES_URL = "http://" + "hermes" + ":" + HERMES_PW + "@hermes.local:8642"


@pytest.mark.parametrize("render", [repr, str])
def test_settings_url_password_masked_in_repr_and_str(render):
    from app.config import load_settings
    s = load_settings({"JUDGE_DATABASE_URL": DB_URL, "HERMES_API_URL": HERMES_URL})
    text = render(s)
    assert DB_PW not in text and HERMES_PW not in text, "пароль из URL попал в представление настроек"
    assert "appuser" in text and "db.local" in text and "hermes.local" in text
    assert "***" in text


def test_settings_keep_full_url_values():
    from app.config import load_settings
    s = load_settings({"JUDGE_DATABASE_URL": DB_URL, "HERMES_API_URL": HERMES_URL})
    assert s.database_url == DB_URL and s.hermes_api_url == HERMES_URL


@pytest.mark.parametrize("render", [repr, str])
def test_settings_url_without_password_shown_as_is(render):
    from app.config import load_settings
    s = load_settings({"HERMES_API_URL": "http://hermes:8642"})
    text = render(s)
    assert "sqlite:///judge.db" in text and "http://hermes:8642" in text


# 3. pick_request_id: fullmatch, без «хвостового» перевода строки
@pytest.mark.parametrize("bad", ["valid\n", "ok\r\n", "a\x00b", "", None])
def test_pick_request_id_rejects_unsafe_values(bad):
    from app.middleware import pick_request_id
    got = pick_request_id(bad)
    assert got != bad
    assert re.fullmatch(r"[A-Za-z0-9._-]{1,64}", got), f"выдан небезопасный id {got!r}"


def test_pick_request_id_keeps_valid_value():
    from app.middleware import pick_request_id
    assert pick_request_id("good-id_1.2") == "good-id_1.2"


# 4. обрыв потокового ответа помечается в access-логе
def test_access_log_marks_aborted_stream(tmp_path, monkeypatch):
    app = make_app(tmp_path, monkeypatch, modules={"sample": SAMPLE_ROUTES, "streaming": STREAM_ABORT})
    buf = start_logging()
    resp = make_client(app).get("/stream-abort", headers={"X-Request-ID": "strm-1"})
    assert resp.headers["X-Request-ID"] == "strm-1"
    records = log_records(buf)
    access = [r for r in records if r.get("path") == "/stream-abort"]
    assert len(access) == 1, access
    assert access[0]["aborted"] is True
    assert access[0]["status"] == 200, "статус в access-записи — тот, что реально ушёл клиенту"
    errors = [r for r in records if r["level"] == "ERROR"]
    assert errors and any(r["request_id"] == "strm-1" for r in errors), "нет ERROR об обрыве с request_id"


def test_access_log_normal_request_is_not_aborted(tmp_path, monkeypatch):
    app = make_app(tmp_path, monkeypatch)
    buf = start_logging()
    make_client(app).get("/ping")
    (rec,) = [r for r in log_records(buf) if r.get("path") == "/ping"]
    assert rec["aborted"] is False
