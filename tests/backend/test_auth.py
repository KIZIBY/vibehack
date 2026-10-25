"""T021: вход общим демо-аккаунтом (login / logout / me), сессионная cookie, защита ``/api/*``,
ограничение попыток входа. Тесты написаны ДО реализации (RED): ``backend/app/auth.py`` и
``backend/app/routers/auth.py`` ещё нет.

Контракт (см. также contracts/openapi.yaml):
- ``create_app(..., clock=time.time)`` — управляемое время; настройка ``cookie_secure`` (``JUDGE_COOKIE_SECURE``);
- любой путь под ``/api/`` без валидной сессии → 401 ``unauthorized`` (в т.ч. несуществующий), кроме ``POST /api/v1/auth/login``;
- login: 204 + ``Set-Cookie: session=<токен>; HttpOnly; Path=/; SameSite=Lax`` (+ ``Secure`` при ``cookie_secure``);
  неверная пара → 401 с одинаковым message; кривое тело → 422; не настроено → 503 ``unavailable``;
  сравнение через ``hmac.compare_digest`` без раннего выхода; 5 попыток/мин с адреса (скользящее окно 60 с) → 429 + Retry-After;
- токен: HMAC от ``session_secret`` с именем, ``jti`` и ``exp = clock() + 12 ч``; на каждом авторизованном
  запросе к ``/api/*`` cookie переиздаётся; logout отзывает ``jti`` на сервере; ``me`` → ``{"username"}``;
- секреты и токены не попадают в журнал; неудачная попытка — запись WARNING.

Допущения (выбраны тестом): тестовые роутеры подключаются через временный пакет, куда добавлен модуль
``from app.routers.auth import router``; cookie ведёт cookie-jar клиента httpx, часы стартуют около реального
«сейчас» (чтобы абсолютные даты в Set-Cookie не оказались «в прошлом» для jar); адрес клиента для лимита
меняется параметром ``TestClient(client=(host, port))``. Все импорты ``app`` — внутри функций.
"""
from __future__ import annotations

import email.utils
import io
import json
import logging
import re
import textwrap
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import jsonschema
import pytest
import yaml

REPO = Path(__file__).resolve().parents[2]
OPENAPI = REPO / "specs" / "001-ai-judge-platform" / "contracts" / "openapi.yaml"

DEMO_USER = "demo-user"
DEMO_PW = "demo-pass-QX1"       # выдуманные значения, настоящих секретов нет
SESSION_SECRET = "session-secret-ZK7"
LOGIN = "/api/v1/auth/login"
LOGOUT = "/api/v1/auth/logout"
ME = "/api/v1/auth/me"
HOUR = 3600


class Clock:
    def __init__(self) -> None:
        self.now = time.time()

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


@pytest.fixture(autouse=True)
def restore_root_logger():
    root = logging.getLogger()
    handlers, level = root.handlers[:], root.level
    yield
    root.handlers[:] = handlers
    root.setLevel(level)


SECURE_ROUTES = '''
from fastapi import APIRouter
router = APIRouter()

@router.get("/api/v1/secret")
def secret_get():
    return {"secret": "data"}

@router.post("/api/v1/secret")
def secret_post():
    return {"secret": "posted"}

@router.get("/open")
def open_route():
    return {"open": True}
'''


def auth_env(**over) -> dict:
    env = {"JUDGE_DEMO_USER": DEMO_USER, "JUDGE_DEMO_PASSWORD": DEMO_PW, "JUDGE_SESSION_SECRET": SESSION_SECRET}
    env.update(over)
    return {k: v for k, v in env.items() if v is not None}


def make_app(tmp_path, monkeypatch, *, env=None, clock=None):
    from app.config import load_settings
    from app.main import create_app
    name = f"ar_{uuid.uuid4().hex[:10]}"
    pkg = tmp_path / name
    pkg.mkdir()
    (pkg / "__init__.py").write_text("")
    (pkg / "authr.py").write_text("from app.routers.auth import router\n")
    (pkg / "secure.py").write_text(textwrap.dedent(SECURE_ROUTES))
    monkeypatch.syspath_prepend(str(tmp_path))
    return create_app(load_settings(auth_env(**(env or {}))), routers_package=name, clock=clock or Clock())


def make_client(app, host: str | None = None):
    from fastapi.testclient import TestClient
    kwargs = {} if host is None else {"client": (host, 4000)}
    return TestClient(app, raise_server_exceptions=False, **kwargs)


def login(client, user: str = DEMO_USER, password: str = DEMO_PW):
    return client.post(LOGIN, json={"username": user, "password": password})


def logged_in(tmp_path, monkeypatch, **env):
    clock = Clock()
    client = make_client(make_app(tmp_path, monkeypatch, env=env or None, clock=clock))
    assert login(client).status_code == 204
    return client, clock


def set_cookie_header(resp) -> str:
    return resp.headers.get("set-cookie", "")


def assert_unauthorized(resp):
    assert resp.status_code == 401, (resp.status_code, resp.text)
    body = resp.json()
    assert body["error"]["code"] == "unauthorized"
    assert body["error"]["request_id"] == resp.headers["X-Request-ID"]


def error_of(resp) -> dict:
    return resp.json()["error"]


# ─────────────────────────────── настройки ───────────────────────────────

def test_cookie_secure_defaults_to_false():
    from app.config import load_settings
    assert load_settings({}).cookie_secure is False


@pytest.mark.parametrize("value,expected", [("true", True), ("1", True), ("yes", True), ("TRUE", True),
                                            ("Yes", True), ("false", False), ("0", False), ("no", False),
                                            ("", False), ("off", False), ("2", False)])
def test_cookie_secure_parsing(value, expected):
    from app.config import load_settings
    assert load_settings({"JUDGE_COOKIE_SECURE": value}).cookie_secure is expected


# ─────────────────────────────── защита /api/* ───────────────────────────────

@pytest.mark.parametrize("method,path", [("GET", "/api/v1/secret"), ("POST", "/api/v1/secret"),
                                         ("GET", "/api/v1/nope"), ("GET", "/api/other"),
                                         ("DELETE", "/api/v1/anything/at/all"),
                                         ("GET", ME), ("POST", LOGOUT), ("GET", LOGIN)])
def test_api_paths_without_session_are_401(tmp_path, monkeypatch, method, path):
    client = make_client(make_app(tmp_path, monkeypatch))
    assert_unauthorized(client.request(method, path))


def test_non_api_paths_do_not_require_session(tmp_path, monkeypatch):
    client = make_client(make_app(tmp_path, monkeypatch))
    assert client.get("/health").status_code == 200
    assert client.get("/open").json() == {"open": True}
    assert client.get("/no/such/page").status_code == 404


def test_api_paths_work_with_session(tmp_path, monkeypatch):
    client, _ = logged_in(tmp_path, monkeypatch)
    assert client.get("/api/v1/secret").json() == {"secret": "data"}
    assert client.post("/api/v1/secret").json() == {"secret": "posted"}


def test_unknown_api_path_with_session_is_404_not_401(tmp_path, monkeypatch):
    client, _ = logged_in(tmp_path, monkeypatch)
    resp = client.get("/api/v1/nope")
    assert resp.status_code == 404 and error_of(resp)["code"] == "not_found"


# ─────────────────────────────── login ───────────────────────────────

def test_login_success_sets_http_only_session_cookie(tmp_path, monkeypatch):
    client = make_client(make_app(tmp_path, monkeypatch))
    resp = login(client)
    assert resp.status_code == 204 and resp.content == b""
    header = set_cookie_header(resp)
    assert header.startswith("session="), header
    assert re.search(r";\s*HttpOnly", header, re.I)
    assert re.search(r";\s*Path=/(;|$)", header, re.I)
    assert re.search(r";\s*SameSite=Lax", header, re.I)
    assert not re.search(r";\s*Secure", header, re.I), "Secure без cookie_secure"


@pytest.mark.parametrize("flag", ["true", "1", "yes", "YES"])
def test_login_cookie_secure_when_enabled(tmp_path, monkeypatch, flag):
    client = make_client(make_app(tmp_path, monkeypatch, env={"JUDGE_COOKIE_SECURE": flag}))
    assert re.search(r";\s*Secure", set_cookie_header(login(client)), re.I)


def test_login_tokens_differ_between_logins_and_hide_secrets(tmp_path, monkeypatch):
    client = make_client(make_app(tmp_path, monkeypatch))
    first = re.match(r"session=([^;]+)", set_cookie_header(login(client))).group(1)
    second = re.match(r"session=([^;]+)", set_cookie_header(login(client))).group(1)
    assert first != second, "jti обязан быть случайным"
    for token in (first, second):
        assert DEMO_PW not in token and SESSION_SECRET not in token


@pytest.mark.parametrize("user,password", [(DEMO_USER, "wrong-password"), ("someone-else", DEMO_PW),
                                           ("someone-else", "wrong-password")])
def test_login_wrong_credentials_is_401_with_identical_message_and_no_cookie(tmp_path, monkeypatch, user, password):
    client = make_client(make_app(tmp_path, monkeypatch))
    resp = login(client, user, password)
    assert_unauthorized(resp)
    assert "set-cookie" not in resp.headers
    reference = login(make_client(make_app(tmp_path, monkeypatch)), DEMO_USER, "another-wrong-password")
    assert error_of(resp)["message"] == error_of(reference)["message"], "message раскрывает, что именно неверно"


@pytest.mark.parametrize("kwargs", [dict(content="not json", headers={"Content-Type": "application/json"}),
                                    dict(json={}), dict(json={"username": DEMO_USER}),
                                    dict(json={"password": DEMO_PW}), dict(json=["list"])])
def test_login_malformed_body_is_422(tmp_path, monkeypatch, kwargs):
    client = make_client(make_app(tmp_path, monkeypatch))
    resp = client.post(LOGIN, **kwargs)
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid"
    assert "set-cookie" not in resp.headers


@pytest.mark.parametrize("missing", ["JUDGE_DEMO_USER", "JUDGE_DEMO_PASSWORD", "JUDGE_SESSION_SECRET"])
def test_login_not_configured_is_503_and_issues_no_session(tmp_path, monkeypatch, missing):
    client = make_client(make_app(tmp_path, monkeypatch, env={missing: None}))
    resp = login(client)
    assert resp.status_code == 503 and error_of(resp)["code"] == "unavailable"
    assert error_of(resp)["request_id"] == resp.headers["X-Request-ID"]
    assert "set-cookie" not in resp.headers
    assert_unauthorized(client.get(ME))


@pytest.mark.parametrize("bad_field", ["user", "password"])
def test_login_compares_both_fields_in_constant_time_without_early_exit(tmp_path, monkeypatch, bad_field):
    import app.auth as auth_module
    client = make_client(make_app(tmp_path, monkeypatch))
    calls: list[tuple] = []
    real = auth_module.hmac.compare_digest

    def counting(a, b):
        calls.append((a, b))
        return real(a, b)

    monkeypatch.setattr(auth_module.hmac, "compare_digest", counting)
    user = "someone-else" if bad_field == "user" else DEMO_USER
    password = "wrong-password" if bad_field == "password" else DEMO_PW
    assert login(client, user, password).status_code == 401
    assert len(calls) >= 2, "compare_digest должен вызываться и для логина, и для пароля (без раннего выхода)"


# ─────────────────────────────── ограничение попыток ───────────────────────────────

def test_sixth_attempt_in_a_minute_is_429_with_retry_after(tmp_path, monkeypatch):
    clock = Clock()
    client = make_client(make_app(tmp_path, monkeypatch, clock=clock))
    assert [login(client, password="wrong-password").status_code for _ in range(5)] == [401] * 5
    resp = login(client)   # даже верный пароль
    assert resp.status_code == 429 and error_of(resp)["code"] == "rate_limited"
    retry_after = resp.headers.get("Retry-After", "")
    assert retry_after.isdigit() and 1 <= int(retry_after) <= 60, retry_after
    assert error_of(resp)["request_id"] == resp.headers["X-Request-ID"]


def test_rate_limit_counts_successful_and_failed_attempts_alike(tmp_path, monkeypatch):
    client = make_client(make_app(tmp_path, monkeypatch))
    outcomes = [login(client).status_code, login(client, password="x").status_code,
                login(client).status_code, login(client, password="y").status_code, login(client).status_code]
    assert outcomes == [204, 401, 204, 401, 204]
    assert login(client).status_code == 429


def test_rate_limit_response_does_not_reveal_password_validity(tmp_path, monkeypatch):
    client = make_client(make_app(tmp_path, monkeypatch))
    for _ in range(5):
        login(client, password="wrong-password")
    good, bad = login(client), login(client, password="wrong-password")
    assert good.status_code == bad.status_code == 429
    assert error_of(good)["message"] == error_of(bad)["message"]
    assert "set-cookie" not in good.headers


def test_rate_limit_window_frees_after_60_seconds(tmp_path, monkeypatch):
    clock = Clock()
    client = make_client(make_app(tmp_path, monkeypatch, clock=clock))
    for _ in range(5):
        login(client, password="wrong-password")
    assert login(client).status_code == 429
    clock.advance(59)
    assert login(client).status_code == 429
    clock.advance(1)
    assert login(client).status_code == 204


def test_rate_limit_window_is_sliding_not_fixed(tmp_path, monkeypatch):
    clock = Clock()
    client = make_client(make_app(tmp_path, monkeypatch, clock=clock))
    for _ in range(3):
        login(client, password="wrong-password")          # t0
    clock.advance(40)
    for _ in range(2):
        login(client, password="wrong-password")          # t0+40
    clock.advance(10)
    assert login(client).status_code == 429               # t0+50: в окне 5 попыток
    clock.advance(10)                                     # t0+60: три первые вышли из окна, две остались
    assert [login(client, password="wrong-password").status_code for _ in range(3)] == [401] * 3
    assert login(client).status_code == 429, "в скользящем окне должно остаться не больше 5 попыток"


def test_rate_limit_is_per_client_address(tmp_path, monkeypatch):
    app = make_app(tmp_path, monkeypatch)
    first, second = make_client(app, "203.0.113.5"), make_client(app, "203.0.113.6")
    for _ in range(5):
        login(first, password="wrong-password")
    assert login(first).status_code == 429
    assert login(second).status_code == 204


def test_rate_limit_applies_only_to_login(tmp_path, monkeypatch):
    client, _ = logged_in(tmp_path, monkeypatch)
    assert [client.get(ME).status_code for _ in range(12)] == [200] * 12


# ─────────────────────────────── me и срок сессии ───────────────────────────────

def test_me_returns_username_matching_openapi(tmp_path, monkeypatch):
    client, _ = logged_in(tmp_path, monkeypatch)
    resp = client.get(ME)
    assert resp.status_code == 200 and resp.json() == {"username": DEMO_USER}
    schema = yaml.safe_load(OPENAPI.read_text(encoding="utf-8"))["paths"][ME]["get"]["responses"]["200"]["content"]["application/json"]["schema"]
    jsonschema.validate(resp.json(), schema)


def test_session_valid_just_before_12_hours(tmp_path, monkeypatch):
    client, clock = logged_in(tmp_path, monkeypatch)
    clock.advance(12 * HOUR - 60)    # 11 ч 59 мин
    assert client.get(ME).status_code == 200


def test_session_expires_after_12_hours_without_activity(tmp_path, monkeypatch):
    client, clock = logged_in(tmp_path, monkeypatch)
    clock.advance(12 * HOUR + 1)
    assert_unauthorized(client.get(ME))


def test_every_authorized_api_request_reissues_cookie(tmp_path, monkeypatch):
    client, clock = logged_in(tmp_path, monkeypatch)
    clock.advance(HOUR)
    resp = client.get("/api/v1/secret")
    assert resp.status_code == 200 and set_cookie_header(resp).startswith("session="), "cookie не переиздана"
    clock.advance(12 * HOUR - 60)    # от входа прошло 13 ч, от переиздания — 11 ч 59 мин
    assert client.get(ME).status_code == 200


def test_sliding_session_extends_by_12_hours_after_each_request(tmp_path, monkeypatch):
    client, clock = logged_in(tmp_path, monkeypatch)
    for _ in range(3):
        clock.advance(12 * HOUR - 60)
        assert client.get(ME).status_code == 200
    clock.advance(12 * HOUR + 1)
    assert_unauthorized(client.get(ME))


def test_non_api_request_does_not_renew_session(tmp_path, monkeypatch):
    client, clock = logged_in(tmp_path, monkeypatch)
    clock.advance(HOUR)
    resp = client.get("/open")
    assert "session=" not in set_cookie_header(resp)
    clock.advance(11 * HOUR + 1)     # от входа 12 ч 0 мин 1 с: /open сессию не продлевал
    assert_unauthorized(client.get(ME))


# ─────────────────────────────── недействительные токены ───────────────────────────────

def _token_of(client) -> str:
    return client.cookies.get("session")


def _fresh_client_with_cookie(app, value: str):
    client = make_client(app)
    client.cookies.set("session", value)
    return client


@pytest.mark.parametrize("garbage", ["garbage", "a.b.c", "....", "x" * 400, "%00", ""])
def test_garbage_session_cookie_is_401(tmp_path, monkeypatch, garbage):
    app = make_app(tmp_path, monkeypatch)
    assert_unauthorized(_fresh_client_with_cookie(app, garbage).get(ME))


def test_tampered_token_is_401(tmp_path, monkeypatch):
    client, _ = logged_in(tmp_path, monkeypatch)
    token = _token_of(client)
    flipped = token[:-1] + ("A" if token[-1] != "A" else "B")
    assert_unauthorized(_fresh_client_with_cookie(client.app, flipped).get(ME))
    assert_unauthorized(_fresh_client_with_cookie(client.app, token[: len(token) // 2]).get(ME))


def test_token_signed_with_other_secret_is_401(tmp_path, monkeypatch):
    donor, _ = logged_in(tmp_path, monkeypatch, JUDGE_SESSION_SECRET="other-secret-AB9")
    token = _token_of(donor)
    victim = make_app(tmp_path, monkeypatch)
    assert_unauthorized(_fresh_client_with_cookie(victim, token).get(ME))


def test_changing_session_secret_revokes_issued_cookies(tmp_path, monkeypatch):
    old, _ = logged_in(tmp_path, monkeypatch)
    token = _token_of(old)
    assert old.get(ME).status_code == 200
    restarted = make_app(tmp_path, monkeypatch, env={"JUDGE_SESSION_SECRET": "rotated-secret-ZZ1"})
    assert_unauthorized(_fresh_client_with_cookie(restarted, token).get(ME))


# ─────────────────────────────── logout ───────────────────────────────

def test_logout_clears_cookie_and_revokes_token_server_side(tmp_path, monkeypatch):
    client, _ = logged_in(tmp_path, monkeypatch)
    stolen = _token_of(client)
    resp = client.post(LOGOUT)
    assert resp.status_code == 204
    header = set_cookie_header(resp)
    assert header.startswith("session="), header
    max_age_zero = re.search(r"Max-Age=0\b", header, re.I)
    expires = re.search(r"Expires=([^;]+)", header, re.I)
    expired_in_past = bool(expires) and email.utils.parsedate_to_datetime(expires.group(1)) < datetime.now(timezone.utc)
    assert max_age_zero or expired_in_past, f"logout не стирает cookie: {header}"
    # та же cookie, подставленная вручную (украденная), больше не работает
    assert_unauthorized(_fresh_client_with_cookie(client.app, stolen).get(ME))


def test_logout_revokes_only_the_logged_out_session(tmp_path, monkeypatch):
    app = make_app(tmp_path, monkeypatch)
    first, second = make_client(app), make_client(app)
    login(first)
    login(second)
    assert first.post(LOGOUT).status_code == 204
    assert second.get(ME).status_code == 200


def test_logout_without_session_is_401(tmp_path, monkeypatch):
    client = make_client(make_app(tmp_path, monkeypatch))
    assert_unauthorized(client.post(LOGOUT))


# ─────────────────────────────── журнал: нет секретов ───────────────────────────────

def test_failed_attempt_logged_as_warning_and_no_secrets_in_logs(tmp_path, monkeypatch):
    from app.logging import configure_logging
    app = make_app(tmp_path, monkeypatch)
    buf = io.StringIO()
    configure_logging(stream=buf)
    client = make_client(app)
    wrong = "wrong-password-LOGME"
    assert login(client, password=wrong).status_code == 401
    assert login(client).status_code == 204
    token = _token_of(client)
    assert client.get(ME).status_code == 200
    assert client.post(LOGOUT).status_code == 204
    text = buf.getvalue()
    records = [json.loads(line) for line in text.splitlines() if line.strip()]
    assert any(r["level"] == "WARNING" for r in records), "нет записи WARNING о неудачной попытке входа"
    for secret in (wrong, DEMO_PW, SESSION_SECRET, token):
        assert secret not in text, f"секрет попал в журнал: {secret[:8]}…"
