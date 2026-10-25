"""T025 (остаток): текст организатора из чата как вводный материал — ``POST …/messages`` в проекте со статусом ``setup``.
Тесты написаны ДО реализации (RED): ``routers/messages.py`` пока не создаёт ``brief``.

Контракт (задание T025, п. 4):
- проект в статусе ``setup``: помимо сообщения текст сохраняется как вводный — файл ``chat-<ULID>.md`` через ``Storage``
  (``kind="briefs"``, содержимое — текст сообщения), строка ``brief`` (``source=chat``, ``status=extracted``,
  ``name`` = имя файла, ``path`` = ``extracted_text_path`` = относительный путь файла);
- в остальных статусах (``intake``, ``evaluating``, ``results``, ``archived``) — как раньше, без ``brief`` и файла;
- ошибка записи файла не теряет сообщение: оно сохраняется (201), в лог пишется ERROR, ``brief`` не создаётся;
- ответ — по-прежнему схема ``Message``.
Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import logging
import re
from pathlib import Path

import pytest
import sqlalchemy as sa

from test_projects import PROJECTS, assert_matches, make_app, make_client, sql

CHAT_NAME = re.compile(r"chat-[0-9A-HJKMNP-TV-Z]{26}\.md")


@pytest.fixture
def app(tmp_path):
    return make_app(tmp_path, JUDGE_DATA_DIR=str(tmp_path / "data"))


@pytest.fixture
def client(app):
    with make_client(app) as c:
        yield c


def seed_project(app, status: str = "setup") -> str:
    from app.common import new_id, utc_now_iso
    project_id, now = new_id(), utc_now_iso()
    sql(app, "INSERT INTO project (id, name, type, status, agents, required_materials, retention_days, "
             "last_activity_at, version, created_at, updated_at) "
             "VALUES (:id, 'Хакатон', 'other', :status, '[]', '[]', 7, :t, 1, :t, :t)",
        {"id": project_id, "status": status, "t": now})
    return project_id


def say(client, project_id: str, text: str):
    return client.post(f"{PROJECTS}/{project_id}/messages", json={"text": text})


def briefs_of(app, project_id: str) -> list[dict]:
    with app.state.engine.connect() as conn:
        return [dict(r) for r in conn.execute(
            sa.text("SELECT * FROM brief WHERE project_id = :p ORDER BY created_at, id"), {"p": project_id}).mappings()]


def messages_of(app, project_id: str) -> list[dict]:
    with app.state.engine.connect() as conn:
        return [dict(r) for r in conn.execute(
            sa.text("SELECT * FROM message WHERE project_id = :p ORDER BY created_at, id"), {"p": project_id}).mappings()]


def data_files(app) -> list[Path]:
    root = Path(app.state.settings.data_dir)
    return sorted(p for p in root.rglob("*") if p.is_file()) if root.exists() else []


def test_setup_project_message_becomes_a_chat_brief(app, client):
    pid = seed_project(app)
    resp = say(client, pid, "  Победитель — команда с лучшей демонстрацией.  ")
    assert resp.status_code == 201
    assert_matches("Message", resp.json())
    [brief] = briefs_of(app, pid)
    assert (brief["source"], brief["status"], brief["reason"]) == ("chat", "extracted", None)
    assert CHAT_NAME.fullmatch(brief["name"])
    assert re.fullmatch(rf"projects/{pid}/briefs/[A-Za-z0-9_-]+/{re.escape(brief['name'])}", brief["path"])
    assert brief["extracted_text_path"] == brief["path"]
    stored = Path(app.state.settings.data_dir) / brief["path"]
    assert stored.read_text(encoding="utf-8") == "Победитель — команда с лучшей демонстрацией."


def test_chat_brief_is_listed_by_briefs_endpoint(app, client):
    pid = seed_project(app)
    say(client, pid, "Требования к проекту")
    items = client.get(f"{PROJECTS}/{pid}/briefs").json()["items"]
    assert len(items) == 1
    assert_matches("Brief", items[0])
    assert (items[0]["source"], items[0]["status"]) == ("chat", "extracted")


def test_each_message_gets_its_own_brief_and_file(app, client):
    pid = seed_project(app)
    say(client, pid, "Первое")
    say(client, pid, "Второе")
    briefs = briefs_of(app, pid)
    assert len(briefs) == 2 and len({b["name"] for b in briefs}) == 2 and len({b["path"] for b in briefs}) == 2
    texts = sorted((Path(app.state.settings.data_dir) / b["path"]).read_text(encoding="utf-8") for b in briefs)
    assert texts == ["Второе", "Первое"]
    assert len(messages_of(app, pid)) == 2


def test_message_itself_is_unchanged_and_not_duplicated(app, client):
    pid = seed_project(app)
    resp = say(client, pid, "Текст")
    body = resp.json()
    assert (body["author"], body["kind"], body["text"]) == ("organizer", "text", "Текст")
    listed = client.get(f"{PROJECTS}/{pid}/messages").json()["items"]
    assert [m["id"] for m in listed] == [body["id"]]


@pytest.mark.parametrize("status", ["intake", "evaluating", "results", "archived"])
def test_other_statuses_do_not_create_briefs(app, client, status):
    pid = seed_project(app, status)
    resp = say(client, pid, "Обычное сообщение")
    assert resp.status_code == 201
    assert briefs_of(app, pid) == []
    assert data_files(app) == []
    assert len(messages_of(app, pid)) == 1


def test_unknown_project_is_still_404_and_creates_nothing(app, client):
    assert say(client, "NOPE", "x").status_code == 404
    assert data_files(app) == []
    with app.state.engine.connect() as conn:
        assert conn.execute(sa.text("SELECT count(*) FROM brief")).scalar_one() == 0


def test_invalid_text_creates_no_brief(app, client):
    pid = seed_project(app)
    assert say(client, pid, "   ").status_code == 422
    assert briefs_of(app, pid) == [] and data_files(app) == []


class BrokenStorage:
    async def save_upload(self, *args, **kwargs):
        raise OSError("disk full")


def test_storage_failure_keeps_the_message_logs_error_and_creates_no_brief(app, client, caplog):
    pid = seed_project(app)
    app.state.storage = BrokenStorage()
    with caplog.at_level(logging.ERROR):
        resp = say(client, pid, "Важное требование")
    assert resp.status_code == 201
    assert_matches("Message", resp.json())
    assert [m["text"] for m in messages_of(app, pid)] == ["Важное требование"]
    assert briefs_of(app, pid) == []
    assert any(record.levelno >= logging.ERROR for record in caplog.records)


def test_storage_failure_message_is_visible_in_chat(app, client):
    pid = seed_project(app)
    app.state.storage = BrokenStorage()
    body = say(client, pid, "Не потеряйся").json()
    listed = client.get(f"{PROJECTS}/{pid}/messages").json()["items"]
    assert [m["id"] for m in listed] == [body["id"]]
