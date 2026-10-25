"""T024: сообщения чата — ``GET``/``POST /api/v1/projects/{id}/messages`` с keyset и ``post_system_message``.
Тесты написаны ДО реализации (RED): ``backend/app/{routers,services,repositories}/messages.py`` ещё нет.

Контракт (contracts/openapi.yaml, data-model.md, задание T024):
- ``GET ?after=&limit=`` — от старых к новым, keyset по ``(created_at, id)``; ``limit`` 1..200 (по умолчанию 50);
  ответ ``{items, next_cursor}``, ``next_cursor`` — ``null`` на последней странице; мусорный ``after`` → 422 ``invalid``;
  несуществующий (или удалённый) проект → 404;
- ``POST {text}`` — 1..20000 символов после обрезки пробелов (иначе 422); создаёт ``author=organizer``, ``kind=text``
  (201, схема ``Message``) и вызывает ``touch_project`` (версия проекта не меняется);
- ``services.messages.post_system_message(session, project_id, kind, text, *, author="system", attachments=None) -> dict``:
  ``kind`` из enum схемы ``Message``, ``author`` из ``organizer|agent|system``, иначе ``ValueError``; неизвестный проект —
  ``LookupError``; с ``touch_project``; возвращает словарь по схеме ``Message``.

Допущения (выбраны тестом): ``attachments`` в ответе есть только если они были заданы; текст хранится обрезанным
по краям (у POST); вложение — словарь с обязательным ``name`` (строка) и необязательным ``material_id`` (строка).
Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import pytest
import sqlalchemy as sa

from test_projects import PROJECTS, assert_matches, db_value, error_of, make_app, make_client, openapi, parse_dt, schema_of, sql

KINDS = ["text", "brief_extracted", "rubric_drafted", "inventory_ready", "run_progress", "run_completed", "warning"]
GARBAGE_CURSORS = ["!!!", "%%%%", "bm90LWpzb24=", "W10=", "WyJvbmx5LW9uZSJd", "eyJhIjoxfQ==", "WzEsMl0="]


def url(project_id: str) -> str:
    return f"{PROJECTS}/{project_id}/messages"


@pytest.fixture
def app(tmp_path):
    return make_app(tmp_path)


@pytest.fixture
def client(app):
    with make_client(app) as c:
        yield c


def seed_project(app, name: str = "Хакатон") -> str:
    """Проект вставляется прямо в БД: тесты сообщений не зависят от роутера проектов (T023)."""
    from app.common import new_id, utc_now_iso
    project_id, now = new_id(), utc_now_iso()
    sql(app, "INSERT INTO project (id, name, type, status, agents, required_materials, retention_days, "
             "last_activity_at, version, created_at, updated_at) "
             "VALUES (:id, :name, 'other', 'setup', '[]', '[]', 7, :t, 1, :t, :t)", {"id": project_id, "name": name, "t": now})
    return project_id


@pytest.fixture
def pid(app):
    return seed_project(app)


def post(client, project_id: str, text: str):
    return client.post(url(project_id), json={"text": text})


def walk(client, project_id: str, limit: int) -> list[dict]:
    items, cursor, pages = [], None, 0
    while True:
        params = {"limit": limit, **({"after": cursor} if cursor else {})}
        body = client.get(url(project_id), params=params).json()
        items += body["items"]
        cursor, pages = body["next_cursor"], pages + 1
        if cursor is None:
            return items
        assert pages < 100, "пагинация не заканчивается"


def message_rows(app, project_id: str) -> list[dict]:
    with app.state.engine.connect() as conn:
        rows = conn.execute(sa.text("SELECT * FROM message WHERE project_id = :p ORDER BY created_at, id"), {"p": project_id})
        return [dict(r) for r in rows.mappings()]


# ─────────────────────────────── доступ и 404 ───────────────────────────────

@pytest.mark.parametrize("method", ["get", "post"])
def test_messages_require_session(app, method):
    with make_client(app, authorized=False) as anonymous:
        resp = getattr(anonymous, method)(url("X"))
    assert resp.status_code == 401 and error_of(resp)["code"] == "unauthorized"


def test_unknown_project_is_404_for_get_and_post(client):
    assert client.get(url("01HZZZZZZZZZZZZZZZZZZZZZZZ")).status_code == 404
    resp = post(client, "01HZZZZZZZZZZZZZZZZZZZZZZZ", "привет")
    assert resp.status_code == 404 and error_of(resp)["code"] == "not_found"


def test_deleted_project_is_404_for_messages(app, client, pid):
    post(client, pid, "до удаления")
    sql(app, "UPDATE project SET deleted_at = :t WHERE id = :id", {"t": "2026-01-01T00:00:00+00:00", "id": pid})
    assert client.get(url(pid)).status_code == 404
    assert post(client, pid, "после").status_code == 404


# ─────────────────────────────── POST ───────────────────────────────

def test_post_creates_organizer_text_message_matching_schema(client, pid):
    resp = post(client, pid, "  Привет, судья  ")
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert body["author"] == "organizer" and body["kind"] == "text" and body["text"] == "Привет, судья"
    assert len(body["id"]) == 26 and "attachments" not in body
    assert_matches("Message", body)
    assert client.get(url(pid)).json()["items"] == [body]


@pytest.mark.parametrize("text", ["", "   ", "\n\t "])
def test_post_rejects_blank_text(client, pid, text):
    resp = post(client, pid, text)
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid"
    assert client.get(url(pid)).json()["items"] == []


@pytest.mark.parametrize("payload", [{}, {"text": None}, {"text": 5}, {"text": ["a"]}, {"msg": "a"}])
def test_post_rejects_invalid_body(client, pid, payload):
    resp = client.post(url(pid), json=payload)
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid"


def test_post_length_limit_applies_after_trim(client, pid):
    assert post(client, pid, "a" * 20001).status_code == 422
    assert post(client, pid, "  " + "a" * 20001 + "  ").status_code == 422
    ok = post(client, pid, "  " + "я" * 20000 + "\n")
    assert ok.status_code == 201 and ok.json()["text"] == "я" * 20000


def test_post_stores_text_verbatim_without_sql_injection(app, client, pid):
    nasty = "x'); DROP TABLE message; -- :param %s \\ \u0000 \U0001F600"
    resp = post(client, pid, nasty)
    assert resp.status_code == 201
    assert client.get(url(pid)).json()["items"][0]["text"] == nasty.strip()
    assert len(message_rows(app, pid)) == 1


def test_post_touches_project_without_bumping_version(app, client, pid):
    old = "2026-01-10T00:00:00.000000+00:00"
    sql(app, "UPDATE project SET last_activity_at = :t WHERE id = :id", {"t": old, "id": pid})
    assert post(client, pid, "жив").status_code == 201
    assert parse_dt(db_value(app, "last_activity_at", pid)) > parse_dt(old)
    assert db_value(app, "version", pid) == 1


def test_failed_post_does_not_touch_project(app, client, pid):
    old = "2026-01-10T00:00:00.000000+00:00"
    sql(app, "UPDATE project SET last_activity_at = :t WHERE id = :id", {"t": old, "id": pid})
    assert post(client, pid, "  ").status_code == 422
    assert parse_dt(db_value(app, "last_activity_at", pid)) == parse_dt(old)


def test_post_is_committed_before_response(app, client, pid):
    post(client, pid, "видно из другой сессии")
    assert [m["text"] for m in message_rows(app, pid)] == ["видно из другой сессии"]


# ─────────────────────────────── GET и keyset ───────────────────────────────

def test_get_empty_chat(client, pid):
    assert client.get(url(pid)).json() == {"items": [], "next_cursor": None}


def test_get_is_oldest_first_and_matches_openapi(client, pid):
    texts = [f"сообщение {i}" for i in range(5)]
    for t in texts:
        post(client, pid, t)
    resp = client.get(url(pid))
    assert resp.status_code == 200
    assert [m["text"] for m in resp.json()["items"]] == texts
    assert resp.json()["next_cursor"] is None
    schema = openapi()["paths"]["/api/v1/projects/{project_id}/messages"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]
    import jsonschema
    jsonschema.validate(resp.json(), {**schema, "components": openapi()["components"]}, format_checker=jsonschema.FormatChecker())


def test_pagination_walks_every_message_once_in_order(client, pid):
    texts = [f"m{i:02d}" for i in range(11)]
    for t in texts:
        post(client, pid, t)
    for limit in (1, 2, 3, 5, 11, 50):
        assert [m["text"] for m in walk(client, pid, limit)] == texts, limit


def test_exact_multiple_gives_null_cursor_on_last_page(client, pid):
    for i in range(4):
        post(client, pid, f"m{i}")
    first = client.get(url(pid), params={"limit": 2}).json()
    assert len(first["items"]) == 2 and first["next_cursor"]
    last = client.get(url(pid), params={"limit": 2, "after": first["next_cursor"]}).json()
    assert [m["text"] for m in last["items"]] == ["m2", "m3"] and last["next_cursor"] is None


def test_default_limit_is_50(client, pid):
    for i in range(51):
        post(client, pid, f"m{i:02d}")
    body = client.get(url(pid)).json()
    assert len(body["items"]) == 50 and body["next_cursor"]
    assert [m["text"] for m in body["items"]][-1] == "m49"


def test_new_message_after_cursor_appears_on_next_page(client, pid):
    for i in range(3):
        post(client, pid, f"m{i}")
    cursor = client.get(url(pid), params={"limit": 3}).json()["next_cursor"]
    assert cursor is None
    first = client.get(url(pid), params={"limit": 2}).json()
    post(client, pid, "новое")
    rest = client.get(url(pid), params={"limit": 10, "after": first["next_cursor"]}).json()
    assert [m["text"] for m in rest["items"]] == ["m2", "новое"]


def test_ties_on_created_at_are_ordered_by_id(app, client, pid):
    stamp = "2026-02-02T10:00:00.000000+00:00"
    ids = ["01HAAAAAAAAAAAAAAAAAAAAAA3", "01HAAAAAAAAAAAAAAAAAAAAAA1", "01HAAAAAAAAAAAAAAAAAAAAAA2"]
    for mid in ids:
        sql(app, "INSERT INTO message (id, project_id, author, kind, text, created_at) "
                 "VALUES (:id, :p, 'system', 'warning', :id, :t)", {"id": mid, "p": pid, "t": stamp})
    assert [m["id"] for m in walk(client, pid, 1)] == sorted(ids)


def test_messages_of_other_projects_are_not_mixed(app, client, pid):
    other = seed_project(app, "другой")
    post(client, pid, "наше")
    post(client, other, "чужое")
    assert [m["text"] for m in client.get(url(pid)).json()["items"]] == ["наше"]
    assert [m["text"] for m in walk(client, other, 1)] == ["чужое"]


def test_cursor_from_another_project_does_not_leak_messages(app, client, pid):
    other = seed_project(app, "другой")
    for i in range(3):
        post(client, other, f"чужое{i}")
        post(client, pid, f"наше{i}")
    cursor = client.get(url(other), params={"limit": 1}).json()["next_cursor"]
    texts = [m["text"] for m in client.get(url(pid), params={"after": cursor}).json()["items"]]
    assert all(t.startswith("наше") for t in texts)


@pytest.mark.parametrize("limit", ["0", "-1", "201", "abc", "1.5", ""])
def test_get_rejects_bad_limit(client, pid, limit):
    resp = client.get(url(pid), params={"limit": limit})
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid"


def test_get_accepts_limit_bounds(client, pid):
    post(client, pid, "a")
    assert client.get(url(pid), params={"limit": 1}).status_code == 200
    assert client.get(url(pid), params={"limit": 200}).status_code == 200


@pytest.mark.parametrize("cursor", GARBAGE_CURSORS + [""])
def test_garbage_cursor_is_422_not_500(client, pid, cursor):
    post(client, pid, "a")
    resp = client.get(url(pid), params={"after": cursor})
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid", (cursor, resp.status_code, resp.text)


# ─────────────────────────────── post_system_message ───────────────────────────────

def system_message(app, project_id: str, kind: str = "warning", text: str = "внимание", **kwargs) -> dict:
    from app.db import session_scope
    from app.services.messages import post_system_message
    with session_scope(app.state.session_factory) as session:
        return post_system_message(session, project_id, kind, text, **kwargs)


@pytest.mark.parametrize("kind", KINDS)
def test_system_message_accepts_every_schema_kind(app, client, pid, kind):
    message = system_message(app, pid, kind)
    assert message["kind"] == kind and message["author"] == "system" and message["text"] == "внимание"
    assert "attachments" not in message
    assert_matches("Message", message)
    assert client.get(url(pid)).json()["items"] == [message]


def test_system_message_kinds_match_openapi_enum():
    assert KINDS == schema_of("Message")["components"]["schemas"]["Message"]["properties"]["kind"]["enum"]


@pytest.mark.parametrize("author", ["organizer", "agent", "system"])
def test_system_message_author_variants(app, pid, author):
    assert system_message(app, pid, author=author)["author"] == author


def test_system_message_with_attachments(app, client, pid):
    attachments = [{"name": "положение.pdf", "material_id": "01HMAT"}, {"name": "ссылка"}]
    message = system_message(app, pid, "brief_extracted", "Вводные приняты", attachments=attachments)
    assert message["attachments"] == attachments
    assert_matches("Message", message)
    assert client.get(url(pid)).json()["items"][0]["attachments"] == attachments


def test_system_message_empty_attachments_list_is_kept(app, pid):
    assert system_message(app, pid, attachments=[])["attachments"] == []


@pytest.mark.parametrize("kind", ["", "note", "TEXT", "chat", None, 5])
def test_system_message_rejects_unknown_kind(app, client, pid, kind):
    with pytest.raises(ValueError):
        system_message(app, pid, kind)
    assert client.get(url(pid)).json()["items"] == []


@pytest.mark.parametrize("author", ["", "bot", "System", None])
def test_system_message_rejects_unknown_author(app, pid, author):
    with pytest.raises(ValueError):
        system_message(app, pid, author=author)


@pytest.mark.parametrize("attachments", ["file", [{"material_id": "x"}], [{"name": 5}], ["name"], [{"name": "a", "material_id": 3}], {"name": "a"}])
def test_system_message_rejects_bad_attachments(app, pid, attachments):
    with pytest.raises(ValueError):
        system_message(app, pid, attachments=attachments)


def test_system_message_unknown_project_raises_lookup_error(app):
    with pytest.raises(LookupError):
        system_message(app, "01HZZZZZZZZZZZZZZZZZZZZZZZ")


def test_system_message_touches_project(app, client, pid):
    old = "2026-01-10T00:00:00.000000+00:00"
    sql(app, "UPDATE project SET last_activity_at = :t WHERE id = :id", {"t": old, "id": pid})
    system_message(app, pid)
    assert parse_dt(db_value(app, "last_activity_at", pid)) > parse_dt(old)
    assert db_value(app, "version", pid) == 1


def test_system_message_text_is_stored_verbatim(app, client, pid):
    text = "  Опись готова: 12 команд  \n"
    assert system_message(app, pid, "inventory_ready", text)["text"] == text
    assert client.get(url(pid)).json()["items"][0]["text"] == text


def test_messages_keep_creation_order_within_one_millisecond(app, client, pid):
    for i in range(30):
        system_message(app, pid, "run_progress", f"шаг {i:02d}")
    assert [m["text"] for m in walk(client, pid, 7)] == [f"шаг {i:02d}" for i in range(30)]
