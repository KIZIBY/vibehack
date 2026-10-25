"""T025, находки ревью (P0/P1 про данные): RED до правки кода.

- сбой commit БД после сохранения файлов не оставляет файлов без строк ``brief`` (загрузка и вводный из чата);
- запрос на загрузку не держит блокировку записи SQLite, пока файлы пишутся на диск: параллельная запись
  в БД во время ``save_upload`` проходит.
Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import pytest
import sqlalchemy as sa

from test_briefs import PROJECTS, all_files, brief_rows, install_intake, seed_project, upload
from test_projects import make_app, make_client


@pytest.fixture
def app(tmp_path):
    application = make_app(tmp_path, JUDGE_DATA_DIR=str(tmp_path / "data"))
    install_intake(application, tmp_path)
    return application


@pytest.fixture
def client(app):
    with make_client(app) as c:
        yield c


def break_commit(monkeypatch):
    from sqlalchemy.orm import Session

    def failing_commit(self):
        raise RuntimeError("commit failed")

    monkeypatch.setattr(Session, "commit", failing_commit)


def test_commit_failure_after_upload_leaves_no_orphan_files(app, client, monkeypatch):
    pid = seed_project(app)
    break_commit(monkeypatch)
    resp = upload(client, pid, [("a.txt", b"x"), ("b.txt", b"y")])
    assert resp.status_code == 500
    monkeypatch.undo()
    assert all_files(app) == []
    assert brief_rows(app) == []


def test_commit_failure_after_chat_brief_leaves_no_orphan_files(app, client, monkeypatch):
    pid = seed_project(app)
    break_commit(monkeypatch)
    resp = client.post(f"{PROJECTS}/{pid}/messages", json={"text": "Требование"})
    assert resp.status_code == 500
    monkeypatch.undo()
    assert all_files(app) == []
    assert brief_rows(app) == []


def test_upload_does_not_hold_database_write_lock_while_saving_files(app, client):
    from app.services.storage import Storage
    pid = seed_project(app)
    real = Storage(app.state.settings.data_dir)
    probe_engine = sa.create_engine(app.state.engine.url, connect_args={"timeout": 0.2})
    seen: list[str] = []

    class ProbingStorage:
        root = real.root

        async def save_upload(self, *args, **kwargs):
            try:
                with probe_engine.begin() as conn:      # параллельная запись, пока файл ещё пишется
                    conn.execute(sa.text("UPDATE project SET name = name WHERE id = :id"), {"id": pid})
                seen.append("write-ok")
            except sa.exc.OperationalError:
                seen.append("write-locked")
            return await real.save_upload(*args, **kwargs)

    app.state.storage = ProbingStorage()
    resp = upload(client, pid, [("a.txt", b"x")])
    assert resp.status_code == 201
    assert seen == ["write-ok"], "транзакция записи открыта до сохранения файла"
