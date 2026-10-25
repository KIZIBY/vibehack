"""T023/T024, находки ревью: (1) значения ``date`` из Postgres не должны ломать проверку дат (раньше — TypeError → 500);
(2) ``last_activity_at`` меняется монотонно: более ранняя по времени запись не сдвигает срок хранения назад (FR-031).
Тесты написаны ДО исправлений (RED). Все импорты ``app`` — внутри функций.
"""
from __future__ import annotations

from datetime import date, datetime, timezone

import pytest

from test_messages import seed_project, url
from test_projects import PROJECTS, create, db_value, make_app, make_client, parse_dt, sql

FUTURE = "2099-01-01T00:00:00.000000+00:00"


@pytest.fixture
def app(tmp_path):
    return make_app(tmp_path)


@pytest.fixture
def client(app):
    with make_client(app) as c:
        yield c


def test_update_project_accepts_date_objects_from_the_database(app, client, monkeypatch):
    """Postgres отдаёт DATE как ``datetime.date``; PATCH присылает ISO-строки — сравнение не должно падать."""
    from app.db import session_scope
    from app.services import projects as service
    pid = create(client, starts_on="2026-11-01", ends_on="2026-11-05")["id"]
    original = service.repo.get

    reads = []

    def get_with_dates(session, project_id):
        row = original(session, project_id)
        reads.append(project_id)
        if len(reads) % 2:    # нечётное чтение — перед проверкой (как из Postgres); чётное — ответ после записи
            row["starts_on"], row["ends_on"] = date(2026, 11, 1), date(2026, 11, 5)
        return row

    monkeypatch.setattr(service.repo, "get", get_with_dates)
    with session_scope(app.state.session_factory) as session:
        with pytest.raises(service.InvalidProject):
            service.update_project(session, pid, 1, {"ends_on": "2026-10-01"})
        with pytest.raises(service.InvalidProject):
            service.update_project(session, pid, 1, {"starts_on": "2026-12-01"})
        reads.clear()
        view = service.update_project(session, pid, 1, {"ends_on": "2026-11-09"})
    assert (view["starts_on"], view["ends_on"]) == ("2026-11-01", "2026-11-09")


def test_touch_never_moves_last_activity_backwards(app, client):
    from app.db import session_scope
    from app.services.projects import touch_project
    pid = create(client)["id"]
    sql(app, "UPDATE project SET last_activity_at = :t WHERE id = :id", {"t": FUTURE, "id": pid})
    with session_scope(app.state.session_factory) as session:
        touch_project(session, pid)    # существующий проект не должен давать LookupError
    assert parse_dt(db_value(app, "last_activity_at", pid)) == parse_dt(FUTURE)


def test_patch_never_moves_last_activity_backwards(app, client):
    pid = create(client)["id"]
    sql(app, "UPDATE project SET last_activity_at = :t WHERE id = :id", {"t": FUTURE, "id": pid})
    assert client.patch(f"{PROJECTS}/{pid}", json={"name": "Y", "expected_version": 1}).status_code == 200
    assert parse_dt(db_value(app, "last_activity_at", pid)) == parse_dt(FUTURE)


def test_message_post_never_moves_last_activity_backwards(app, client):
    pid = seed_project(app)
    sql(app, "UPDATE project SET last_activity_at = :t WHERE id = :id", {"t": FUTURE, "id": pid})
    assert client.post(url(pid), json={"text": "привет"}).status_code == 201
    assert parse_dt(db_value(app, "last_activity_at", pid)) == parse_dt(FUTURE)


def test_advance_status_never_moves_last_activity_backwards(app, client):
    from app.db import session_scope
    from app.services.projects import advance_status
    pid = create(client)["id"]
    sql(app, "UPDATE project SET last_activity_at = :t WHERE id = :id", {"t": FUTURE, "id": pid})
    with session_scope(app.state.session_factory) as session:
        advance_status(session, pid, "intake")
    assert parse_dt(db_value(app, "last_activity_at", pid)) == parse_dt(FUTURE)


def test_activity_still_moves_forward_from_the_past(app, client):
    pid = create(client)["id"]
    sql(app, "UPDATE project SET last_activity_at = :t WHERE id = :id", {"t": "2026-01-10T00:00:00.000000+00:00", "id": pid})
    assert client.patch(f"{PROJECTS}/{pid}", json={"name": "Y", "expected_version": 1}).status_code == 200
    assert parse_dt(db_value(app, "last_activity_at", pid)) > datetime(2026, 6, 1, tzinfo=timezone.utc)
