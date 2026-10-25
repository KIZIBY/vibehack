"""T023: проекты — CRUD ``/api/v1/projects``, значения по умолчанию по типу (FR-003), статусы, ``touch_project``.
Тесты написаны ДО реализации (RED): ``backend/app/{routers,services,repositories}/projects.py`` ещё нет.

Контракт (contracts/openapi.yaml, data-model.md, задание T023):
- ``GET /api/v1/projects?include_archived=false`` — новые сверху (``created_at`` убыв.), архивные и удалённые скрыты;
- ``POST`` — 201 по ``ProjectCreate``: ``name`` 1–120 символов после обрезки пробелов, ``type`` из enum, даты необязательны,
  ``ends_on`` не раньше ``starts_on`` (иначе 422); ``status=setup``, ``version=1``, ``retention_days`` из настроек,
  агенты и обязательные материалы — по таблице типа;
- ``GET /{id}`` — 404, если проекта нет или ``deleted_at`` не NULL;
- ``PATCH /{id}`` — частичное обновление через ``update_versioned``: устаревший ``expected_version`` → 409 ``version_conflict``,
  неизвестный id → 404, лишние поля (``status``) → 422, ``archived`` true/false (возврат: ``setup`` либо ``intake``);
- ответ строго по схеме ``Project``: ``purge_at = last_activity_at + retention_days``, ``cost_usd = null``;
- ``services.projects.advance_status(session, project_id, target)`` — таблица переходов, недопустимый → ``ValueError``;
- ``services.projects.touch_project(session, project_id)`` — обновляет ``last_activity_at``, версию не трогает.

Допущения (выбраны тестом): ``archived → archived`` — недопустимый переход (``ValueError``), а PATCH ``archived: true``
для уже архивного проекта — без ошибки; неизвестный id в сервисных функциях — ``LookupError``.
Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path

import jsonschema
import pytest
import sqlalchemy as sa
import yaml
from alembic import command
from alembic.config import Config

REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / "backend"
OPENAPI = REPO / "specs" / "001-ai-judge-platform" / "contracts" / "openapi.yaml"
SESSION_SECRET = "session-secret-ZK7"      # выдуманное значение
PROJECTS = "/api/v1/projects"

DEFAULTS = {
    "product_hackathon": (["code", "business", "design", "critic-uniqueness", "critic-honesty"], ["repository"]),
    "ml_hackathon": (["code", "business", "critic-uniqueness", "critic-honesty"], ["repository", "presentation"]),
    "homework": (["code", "business", "critic-uniqueness", "critic-honesty"], []),
    "other": (["code", "business", "design", "critic-uniqueness", "critic-honesty"], ["repository"]),
}


# ─────────────────────────────── хелперы ───────────────────────────────

def openapi() -> dict:
    return yaml.safe_load(OPENAPI.read_text(encoding="utf-8"))


def schema_of(name: str) -> dict:
    doc = openapi()
    return {"$ref": f"#/components/schemas/{name}", "components": doc["components"]}


def assert_matches(name: str, payload) -> None:
    jsonschema.validate(payload, schema_of(name), format_checker=jsonschema.FormatChecker())


def make_cfg(url: str) -> Config:
    cfg = Config(str(BACKEND / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND / "migrations"))
    cfg.set_main_option("sqlalchemy.url", url)
    return cfg


def make_app(tmp_path, **env):
    from app.config import load_settings
    from app.main import create_app
    url = f"sqlite:///{tmp_path / 'db.sqlite'}"
    command.upgrade(make_cfg(url), "head")
    settings = load_settings({"JUDGE_DATABASE_URL": url, "JUDGE_SESSION_SECRET": SESSION_SECRET, **env})
    return create_app(settings)


def make_client(app, *, authorized: bool = True):
    from fastapi.testclient import TestClient
    client = TestClient(app, raise_server_exceptions=False)
    if authorized:
        client.cookies.set("session", app.state.sessions.issue("demo"))
    return client


@pytest.fixture
def app(tmp_path):
    return make_app(tmp_path)


@pytest.fixture
def client(app):
    with make_client(app) as c:
        yield c


def create(client, name: str = "Хакатон", type_: str = "product_hackathon", **extra):
    resp = client.post(PROJECTS, json={"name": name, "type": type_, **extra})
    assert resp.status_code == 201, (resp.status_code, resp.text)
    return resp.json()


def sql(app, statement: str, params: dict | None = None):
    with app.state.engine.begin() as conn:
        return conn.execute(sa.text(statement), params or {})


def db_value(app, column: str, project_id: str):
    with app.state.engine.connect() as conn:
        return conn.execute(sa.text(f"SELECT {column} FROM project WHERE id = :id"), {"id": project_id}).scalar_one()


def parse_dt(value: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def error_of(resp) -> dict:
    return resp.json()["error"]


# ─────────────────────────────── доступ ───────────────────────────────

@pytest.mark.parametrize("method,path", [("get", PROJECTS), ("post", PROJECTS),
                                         ("get", f"{PROJECTS}/X"), ("patch", f"{PROJECTS}/X")])
def test_projects_require_session(app, method, path):
    with make_client(app, authorized=False) as anonymous:
        resp = getattr(anonymous, method)(path)
    assert resp.status_code == 401 and error_of(resp)["code"] == "unauthorized"


# ─────────────────────────────── создание ───────────────────────────────

@pytest.mark.parametrize("type_", sorted(DEFAULTS))
def test_create_applies_type_defaults(client, type_):
    body = create(client, type_=type_)
    agents, required = DEFAULTS[type_]
    assert body["agents"] == agents and body["required_materials"] == required
    assert body["type"] == type_ and body["status"] == "setup" and body["version"] == 1
    assert_matches("Project", body)


def test_create_response_is_strictly_the_project_schema(client):
    body = create(client, name="  Хакатон 2026  ", starts_on="2026-11-01", ends_on="2026-11-03")
    allowed = set(schema_of("Project")["components"]["schemas"]["Project"]["properties"])
    assert set(body) <= allowed
    assert body["name"] == "Хакатон 2026"
    assert (body["starts_on"], body["ends_on"]) == ("2026-11-01", "2026-11-03")
    assert body["cost_usd"] is None and body["rubric_confirmed_version"] is None
    assert body["id"] and len(body["id"]) == 26
    assert body["created_at"] == body["updated_at"]


def test_create_dates_are_optional_and_null(client):
    body = create(client)
    assert body["starts_on"] is None and body["ends_on"] is None
    assert create(client, starts_on=None, ends_on=None)["starts_on"] is None


def test_create_takes_retention_days_from_settings(tmp_path):
    app = make_app(tmp_path, JUDGE_RETENTION_DAYS="3")
    with make_client(app) as c:
        body = create(c)
    assert body["retention_days"] == 3
    delta = parse_dt(body["purge_at"]) - parse_dt(body["created_at"])
    assert delta == timedelta(days=3)


def test_purge_at_is_last_activity_plus_retention_days(app, client):
    body = create(client)
    assert body["retention_days"] == 7
    assert parse_dt(body["purge_at"]) - parse_dt(body["created_at"]) == timedelta(days=7)
    sql(app, "UPDATE project SET last_activity_at = :t WHERE id = :id",
        {"t": "2026-01-10T00:00:00.000000+00:00", "id": body["id"]})
    again = client.get(f"{PROJECTS}/{body['id']}").json()
    assert parse_dt(again["purge_at"]) == datetime(2026, 1, 17, tzinfo=timezone.utc)
    assert_matches("Project", again)


def test_last_activity_equals_created_at_on_create(app, client):
    body = create(client)
    assert parse_dt(db_value(app, "last_activity_at", body["id"])) == parse_dt(body["created_at"])


@pytest.mark.parametrize("name", ["", "   ", "\t\n"])
def test_create_rejects_blank_name(client, name):
    resp = client.post(PROJECTS, json={"name": name, "type": "other"})
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid"


def test_create_name_length_limit_applies_after_trim(client):
    assert client.post(PROJECTS, json={"name": "я" * 121, "type": "other"}).status_code == 422
    assert client.post(PROJECTS, json={"name": " " + "я" * 121, "type": "other"}).status_code == 422
    assert create(client, name="  " + "я" * 120 + "  ")["name"] == "я" * 120


@pytest.mark.parametrize("payload", [
    {"type": "other"},
    {"name": "X"},
    {"name": "X", "type": "unknown"},
    {"name": 5, "type": "other"},
    {"name": "X", "type": "other", "starts_on": "01.11.2026"},
    {"name": "X", "type": "other", "starts_on": "2026-13-40"},
    {"name": "X", "type": "other", "ends_on": 20261101},
    {"name": "X", "type": "other", "starts_on": "2026-11-03", "ends_on": "2026-11-01"},
    {"name": "X", "type": "other", "status": "results"},
])
def test_create_rejects_invalid_payload(client, payload):
    resp = client.post(PROJECTS, json=payload)
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid", resp.text


def test_create_allows_same_day_competition(client):
    body = create(client, starts_on="2026-11-01", ends_on="2026-11-01")
    assert body["starts_on"] == body["ends_on"] == "2026-11-01"


def test_create_stores_name_verbatim_without_sql_injection(app, client):
    nasty = "x'); DROP TABLE project; --"
    body = create(client, name=nasty)
    assert client.get(f"{PROJECTS}/{body['id']}").json()["name"] == nasty
    assert db_value(app, "count(*)", body["id"]) == 1


# ─────────────────────────────── чтение и список ───────────────────────────────

def test_get_returns_project_matching_schema(client):
    body = create(client)
    resp = client.get(f"{PROJECTS}/{body['id']}")
    assert resp.status_code == 200 and resp.json() == body
    assert_matches("Project", resp.json())


def test_get_unknown_project_is_404_in_error_format(client):
    resp = client.get(f"{PROJECTS}/01HZZZZZZZZZZZZZZZZZZZZZZZ")
    assert resp.status_code == 404 and error_of(resp)["code"] == "not_found"


def test_get_soft_deleted_project_is_404(app, client):
    body = create(client)
    sql(app, "UPDATE project SET deleted_at = :t WHERE id = :id", {"t": "2026-01-01T00:00:00+00:00", "id": body["id"]})
    assert client.get(f"{PROJECTS}/{body['id']}").status_code == 404
    assert client.patch(f"{PROJECTS}/{body['id']}", json={"name": "Y", "expected_version": 1}).status_code == 404
    assert client.get(PROJECTS).json()["items"] == []


def test_list_is_newest_first_and_matches_openapi(client):
    ids = [create(client, name=f"П{i}")["id"] for i in range(4)]
    resp = client.get(PROJECTS)
    assert resp.status_code == 200
    assert [p["id"] for p in resp.json()["items"]] == ids[::-1]
    schema = openapi()["paths"][PROJECTS]["get"]["responses"]["200"]["content"]["application/json"]["schema"]
    jsonschema.validate(resp.json(), {**schema, "components": openapi()["components"]},
                        format_checker=jsonschema.FormatChecker())


def test_list_orders_by_created_at_descending(app, client):
    first, second, third = (create(client, name=n)["id"] for n in "abc")
    for pid, ts in ((first, "2026-03-01T00:00:00.000000+00:00"), (second, "2026-01-01T00:00:00.000000+00:00"),
                    (third, "2026-02-01T00:00:00.000000+00:00")):
        sql(app, "UPDATE project SET created_at = :t WHERE id = :id", {"t": ts, "id": pid})
    assert [p["id"] for p in client.get(PROJECTS).json()["items"]] == [first, third, second]


def test_list_hides_archived_by_default(client):
    keep, gone = create(client, name="keep"), create(client, name="gone")
    client.patch(f"{PROJECTS}/{gone['id']}", json={"archived": True, "expected_version": gone["version"]})
    assert [p["id"] for p in client.get(PROJECTS).json()["items"]] == [keep["id"]]
    assert [p["id"] for p in client.get(PROJECTS, params={"include_archived": "false"}).json()["items"]] == [keep["id"]]
    shown = client.get(PROJECTS, params={"include_archived": "true"}).json()["items"]
    assert [p["id"] for p in shown] == [gone["id"], keep["id"]]


def test_list_rejects_garbage_include_archived(client):
    assert client.get(PROJECTS, params={"include_archived": "maybe"}).status_code == 422


def test_list_empty(client):
    assert client.get(PROJECTS).json() == {"items": []}


# ─────────────────────────────── PATCH ───────────────────────────────

def test_patch_renames_and_bumps_version(client):
    body = create(client)
    resp = client.patch(f"{PROJECTS}/{body['id']}", json={"name": "  Новое имя ", "expected_version": 1})
    assert resp.status_code == 200, resp.text
    patched = resp.json()
    assert patched["name"] == "Новое имя" and patched["version"] == 2
    assert patched["agents"] == body["agents"] and patched["type"] == body["type"]
    assert parse_dt(patched["updated_at"]) >= parse_dt(body["updated_at"])
    assert patched["created_at"] == body["created_at"]
    assert_matches("Project", patched)
    assert client.get(f"{PROJECTS}/{body['id']}").json() == patched


def test_patch_updates_agents_materials_and_dates_partially(client):
    body = create(client, starts_on="2026-11-01", ends_on="2026-11-05")
    resp = client.patch(f"{PROJECTS}/{body['id']}", json={
        "agents": ["code", "human"], "required_materials": ["repository", "screencast"], "expected_version": 1})
    patched = resp.json()
    assert (patched["agents"], patched["required_materials"]) == (["code", "human"], ["repository", "screencast"])
    assert (patched["starts_on"], patched["ends_on"], patched["name"]) == ("2026-11-01", "2026-11-05", body["name"])
    cleared = client.patch(f"{PROJECTS}/{body['id']}", json={"ends_on": None, "expected_version": 2}).json()
    assert cleared["ends_on"] is None and cleared["starts_on"] == "2026-11-01" and cleared["version"] == 3


def test_patch_stale_version_is_409_and_changes_nothing(client):
    body = create(client)
    assert client.patch(f"{PROJECTS}/{body['id']}", json={"name": "A", "expected_version": 1}).status_code == 200
    resp = client.patch(f"{PROJECTS}/{body['id']}", json={"name": "B", "expected_version": 1})
    assert resp.status_code == 409 and error_of(resp)["code"] == "version_conflict"
    assert client.get(f"{PROJECTS}/{body['id']}").json()["name"] == "A"


def test_patch_unknown_project_is_404_even_with_any_version(client):
    resp = client.patch(f"{PROJECTS}/01HZZZZZZZZZZZZZZZZZZZZZZZ", json={"name": "A", "expected_version": 5})
    assert resp.status_code == 404 and error_of(resp)["code"] == "not_found"


@pytest.mark.parametrize("payload", [
    {"name": "A"},                                           # нет expected_version
    {"expected_version": -1},
    {"expected_version": "1"},
    {"name": "", "expected_version": 1},
    {"name": "   ", "expected_version": 1},
    {"name": "я" * 121, "expected_version": 1},
    {"name": None, "expected_version": 1},
    {"agents": ["wizard"], "expected_version": 1},
    {"agents": "code", "expected_version": 1},
    {"required_materials": ["video"], "expected_version": 1},
    {"starts_on": "tomorrow", "expected_version": 1},
    {"archived": "yes", "expected_version": 1},
    {"status": "results", "expected_version": 1},            # прямая смена статуса невозможна
    {"type": "homework", "expected_version": 1},
])
def test_patch_rejects_invalid_payload_and_changes_nothing(client, payload):
    body = create(client)
    resp = client.patch(f"{PROJECTS}/{body['id']}", json=payload)
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid", resp.text
    assert client.get(f"{PROJECTS}/{body['id']}").json() == body


def test_patch_checks_dates_against_stored_values(client):
    body = create(client, starts_on="2026-11-01", ends_on="2026-11-05")
    early = client.patch(f"{PROJECTS}/{body['id']}", json={"ends_on": "2026-10-01", "expected_version": 1})
    late = client.patch(f"{PROJECTS}/{body['id']}", json={"starts_on": "2026-12-01", "expected_version": 1})
    both_ok = client.patch(f"{PROJECTS}/{body['id']}",
                           json={"starts_on": "2026-12-01", "ends_on": "2026-12-02", "expected_version": 1})
    assert (early.status_code, late.status_code, both_ok.status_code) == (422, 422, 200)


def test_patch_archive_sets_status_and_hides_from_list(client):
    body = create(client)
    archived = client.patch(f"{PROJECTS}/{body['id']}", json={"archived": True, "expected_version": 1}).json()
    assert archived["status"] == "archived" and archived["version"] == 2
    assert client.get(f"{PROJECTS}/{body['id']}").json()["status"] == "archived"
    again = client.patch(f"{PROJECTS}/{body['id']}", json={"archived": True, "expected_version": 2})
    assert again.status_code == 200 and again.json()["status"] == "archived"


def test_patch_unarchive_returns_to_setup_without_confirmed_rubric(client):
    body = create(client)
    client.patch(f"{PROJECTS}/{body['id']}", json={"archived": True, "expected_version": 1})
    restored = client.patch(f"{PROJECTS}/{body['id']}", json={"archived": False, "expected_version": 2}).json()
    assert restored["status"] == "setup" and restored["version"] == 3


def test_patch_unarchive_returns_to_intake_with_confirmed_rubric(app, client):
    body = create(client)
    client.patch(f"{PROJECTS}/{body['id']}", json={"archived": True, "expected_version": 1})
    sql(app, "UPDATE project SET rubric_confirmed_version = 2 WHERE id = :id", {"id": body["id"]})
    restored = client.patch(f"{PROJECTS}/{body['id']}", json={"archived": False, "expected_version": 2}).json()
    assert restored["status"] == "intake" and restored["rubric_confirmed_version"] == 2


def test_patch_archived_false_on_active_project_keeps_status(app, client):
    body = create(client)
    sql(app, "UPDATE project SET status = 'evaluating' WHERE id = :id", {"id": body["id"]})
    assert client.patch(f"{PROJECTS}/{body['id']}", json={"archived": False, "expected_version": 1}).json()["status"] == "evaluating"


def test_patch_archive_works_from_any_status(app, client):
    for status in ("setup", "intake", "evaluating", "results"):
        body = create(client)
        sql(app, "UPDATE project SET status = :s WHERE id = :id", {"s": status, "id": body["id"]})
        assert client.patch(f"{PROJECTS}/{body['id']}", json={"archived": True, "expected_version": 1}).json()["status"] == "archived"


def test_patch_touches_last_activity(app, client):
    body = create(client)
    old = "2026-01-10T00:00:00.000000+00:00"
    sql(app, "UPDATE project SET last_activity_at = :t WHERE id = :id", {"t": old, "id": body["id"]})
    patched = client.patch(f"{PROJECTS}/{body['id']}", json={"name": "Z", "expected_version": 1}).json()
    assert parse_dt(db_value(app, "last_activity_at", body["id"])) > parse_dt(old)
    assert parse_dt(patched["purge_at"]) > datetime(2026, 6, 1, tzinfo=timezone.utc)


def test_two_patches_with_same_version_second_gets_409(client):
    body = create(client)
    first = client.patch(f"{PROJECTS}/{body['id']}", json={"name": "первый", "expected_version": 1})
    second = client.patch(f"{PROJECTS}/{body['id']}", json={"agents": ["code"], "expected_version": 1})
    assert (first.status_code, second.status_code) == (200, 409)
    final = client.get(f"{PROJECTS}/{body['id']}").json()
    assert final["name"] == "первый" and final["agents"] == body["agents"] and final["version"] == 2


def test_concurrent_patches_never_lose_a_write(app, client):
    body = create(client)
    outcomes: list[int] = []
    barrier = threading.Barrier(6)

    def worker(n: int) -> None:
        from fastapi.testclient import TestClient
        with TestClient(app, raise_server_exceptions=False) as c:
            c.cookies.set("session", app.state.sessions.issue("demo"))
            barrier.wait()
            outcomes.append(c.patch(f"{PROJECTS}/{body['id']}", json={"name": f"w{n}", "expected_version": 1}).status_code)

    threads = [threading.Thread(target=worker, args=(n,)) for n in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(outcomes) == [200] + [409] * 5, outcomes
    assert client.get(f"{PROJECTS}/{body['id']}").json()["version"] == 2


# ─────────────────────────────── сервисы: статусы ───────────────────────────────

def status_in_db(app, project_id: str) -> str:
    return db_value(app, "status", project_id)


def seeded(app, client, status: str) -> str:
    pid = create(client)["id"]
    sql(app, "UPDATE project SET status = :s WHERE id = :id", {"s": status, "id": pid})
    return pid


@pytest.mark.parametrize("start,target", [
    ("setup", "intake"), ("intake", "evaluating"), ("evaluating", "results"), ("results", "evaluating"),
    ("setup", "archived"), ("intake", "archived"), ("evaluating", "archived"), ("results", "archived"),
])
def test_advance_status_allowed_transitions(app, client, start, target):
    from app.db import session_scope
    from app.services.projects import advance_status
    pid = seeded(app, client, start)
    version_before = db_value(app, "version", pid)
    with session_scope(app.state.session_factory) as session:
        advance_status(session, pid, target)
    assert status_in_db(app, pid) == target
    assert db_value(app, "version", pid) == version_before + 1


@pytest.mark.parametrize("start,target", [
    ("setup", "evaluating"), ("setup", "results"), ("setup", "setup"), ("intake", "setup"), ("intake", "results"),
    ("intake", "intake"), ("evaluating", "setup"), ("evaluating", "intake"), ("evaluating", "evaluating"),
    ("results", "setup"), ("results", "intake"), ("results", "results"),
    ("archived", "setup"), ("archived", "intake"), ("archived", "evaluating"), ("archived", "results"),
    ("archived", "archived"),
])
def test_advance_status_rejects_other_transitions(app, client, start, target):
    from app.db import session_scope
    from app.services.projects import advance_status
    pid = seeded(app, client, start)
    with pytest.raises(ValueError):
        with session_scope(app.state.session_factory) as session:
            advance_status(session, pid, target)
    assert status_in_db(app, pid) == start


def test_advance_status_rejects_unknown_target_and_project(app, client):
    from app.db import session_scope
    from app.services.projects import advance_status
    pid = seeded(app, client, "setup")
    with session_scope(app.state.session_factory) as session:
        with pytest.raises(ValueError):
            advance_status(session, pid, "finished")
        with pytest.raises(LookupError):
            advance_status(session, "01HZZZZZZZZZZZZZZZZZZZZZZZ", "intake")


# ─────────────────────────────── сервисы: touch_project ───────────────────────────────

def test_touch_project_updates_last_activity_only(app, client):
    from app.db import session_scope
    from app.services.projects import touch_project
    pid = create(client)["id"]
    old = "2026-01-10T00:00:00.000000+00:00"
    sql(app, "UPDATE project SET last_activity_at = :t WHERE id = :id", {"t": old, "id": pid})
    before = client.get(f"{PROJECTS}/{pid}").json()
    with session_scope(app.state.session_factory) as session:
        touch_project(session, pid)
    after = client.get(f"{PROJECTS}/{pid}").json()
    assert parse_dt(db_value(app, "last_activity_at", pid)) > datetime(2026, 6, 1, tzinfo=timezone.utc)
    assert after["version"] == before["version"] == 1 and after["updated_at"] == before["updated_at"]
    assert parse_dt(after["purge_at"]) > parse_dt(before["purge_at"])


def test_touch_project_unknown_or_deleted_project_raises_lookup_error(app, client):
    from app.db import session_scope
    from app.services.projects import touch_project
    pid = create(client)["id"]
    sql(app, "UPDATE project SET deleted_at = :t WHERE id = :id", {"t": "2026-01-01T00:00:00+00:00", "id": pid})
    with session_scope(app.state.session_factory) as session:
        with pytest.raises(LookupError):
            touch_project(session, pid)
        with pytest.raises(LookupError):
            touch_project(session, "01HZZZZZZZZZZZZZZZZZZZZZZZ")

