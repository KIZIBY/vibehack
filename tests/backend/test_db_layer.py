"""T022: слой данных — движок и сессии (app.db), оптимистичная запись, keyset-пагинация, 409 на конфликт версий.

Тесты написаны ДО реализации (RED): ``backend/app/db.py`` и ``backend/app/repositories/base.py`` ещё нет.

Контракт:
- ``make_engine(url)``: SQLite — на каждом соединении ``PRAGMA foreign_keys=ON``, ``busy_timeout`` >= 5000 мс,
  ``check_same_thread=False``; другие диалекты — обычный ``create_engine``. ``make_session_factory(engine)``
  (``expire_on_commit=False``), ``session_scope(factory)`` (commit при успехе, rollback при исключении);
- ``create_app`` кладёт ``app.state.engine`` / ``app.state.session_factory`` (без подключения до первого запроса),
  на shutdown вызывает ``engine.dispose()``; зависимость ``get_session`` — сессия на запрос;
- ``repositories.base``: ``VersionConflict``, ``update_versioned``, ``encode_cursor`` / ``decode_cursor``, ``keyset_page``;
- ``VersionConflict`` → 409 ``version_conflict`` в формате Error.

Допущения (выбраны тестом): ``keyset_page`` возвращает ``created_at`` как есть из БД (строка при сыром SQL);
на ровно кратном остатке (``limit`` == числу оставшихся строк) ``next_cursor`` — ``None``; курсор проверяется
только на «мусор» (пусто, не base64, base64 не того формата), без попыток угадать внутренний формат.
Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import random
import re
import textwrap
import threading
import uuid
from pathlib import Path

import jsonschema
import pytest
import sqlalchemy as sa
import yaml
from alembic import command
from alembic.config import Config
from sqlalchemy import exc as sa_exc

REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / "backend"
OPENAPI = REPO / "specs" / "001-ai-judge-platform" / "contracts" / "openapi.yaml"
TS = "2026-01-01 00:00:00.000000"


# ─────────────────────────────── хелперы ───────────────────────────────

def make_cfg(url: str) -> Config:
    cfg = Config(str(BACKEND / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND / "migrations"))
    cfg.set_main_option("sqlalchemy.url", url)
    return cfg


def migrated_url(tmp_path: Path, name: str = "db.sqlite") -> str:
    url = f"sqlite:///{tmp_path / name}"
    command.upgrade(make_cfg(url), "head")
    return url


INSERT_PROJECT = sa.text(
    "INSERT INTO project (id, name, type, status, agents, required_materials, retention_days, "
    "last_activity_at, version, created_at, updated_at) "
    "VALUES (:id, :name, 'other', 'setup', '[]', '{}', 7, :ts, :version, :ts, :ts)")
INSERT_MESSAGE = sa.text(
    "INSERT INTO message (id, project_id, author, kind, text, created_at) "
    "VALUES (:id, :pid, 'system', 'note', 'text', :ts)")


def add_project(session, pid: str = "P1", name: str = "Demo", version: int = 1) -> None:
    session.execute(INSERT_PROJECT, {"id": pid, "name": name, "version": version, "ts": TS})


def add_message(session, mid: str, ts: str, pid: str = "P1") -> None:
    session.execute(INSERT_MESSAGE, {"id": mid, "pid": pid, "ts": ts})


def project_row(session, pid: str = "P1"):
    return session.execute(sa.text("SELECT name, status, version FROM project WHERE id = :id"), {"id": pid}).one()


def count(session, table: str) -> int:
    return session.execute(sa.text(f"SELECT count(*) FROM {table}")).scalar_one()


def seed_messages(factory, total: int = 120) -> list[str]:
    """total сообщений проекта P1; created_at с ничьими по 10 штук; вставка в случайном порядке."""
    from app.db import session_scope
    items = [(f"M{i:03d}", f"2026-01-01 00:{i // 10:02d}:00.000000") for i in range(total)]
    random.Random(7).shuffle(items)
    with session_scope(factory) as s:
        add_project(s)
        for mid, ts in items:
            add_message(s, mid, ts)
    return [mid for mid, _ in sorted(items, key=lambda it: (it[1], it[0]))]


def new_factory(tmp_path: Path):
    from app.db import make_engine, make_session_factory
    engine = make_engine(migrated_url(tmp_path))
    return engine, make_session_factory(engine)


def all_pages(factory, *, limit: int, where=None, params=None, after=None, hook=None) -> list[str]:
    from app.db import session_scope
    from app.repositories.base import keyset_page
    ids: list[str] = []
    cursor = after
    pages = 0
    while True:
        with session_scope(factory) as s:
            rows, cursor = keyset_page(s, "message", limit=limit, after=cursor, where=where, params=params)
        ids += [r["id"] for r in rows]
        pages += 1
        if hook is not None:
            hook(pages, rows, cursor)
        if cursor is None:
            return ids
        assert pages < 500, "пагинация не заканчивается"


# ─────────────────────────────── make_engine ───────────────────────────────

def test_make_engine_enables_foreign_keys_on_every_sqlite_connection(tmp_path):
    from app.db import make_engine
    engine = make_engine(f"sqlite:///{tmp_path / 'fk.db'}")
    conns = [engine.raw_connection() for _ in range(3)]   # одновременно — три разных соединения пула
    try:
        for c in conns:
            assert c.cursor().execute("PRAGMA foreign_keys").fetchone()[0] == 1
    finally:
        for c in conns:
            c.close()
    engine.dispose()
    with engine.connect() as conn:   # новое соединение после dispose тоже с foreign_keys=ON
        assert conn.exec_driver_sql("PRAGMA foreign_keys").scalar() == 1


def test_make_engine_sets_busy_timeout(tmp_path):
    from app.db import make_engine
    with make_engine(f"sqlite:///{tmp_path / 'bt.db'}").connect() as conn:
        assert conn.exec_driver_sql("PRAGMA busy_timeout").scalar() >= 5000


def test_make_engine_sqlite_connection_usable_from_another_thread(tmp_path):
    from app.db import make_engine
    raw = make_engine(f"sqlite:///{tmp_path / 'th.db'}").raw_connection()
    outcome: list[str] = []

    def work():
        try:
            outcome.append(str(raw.cursor().execute("SELECT 1").fetchone()[0]))
        except Exception as exc:   # noqa: BLE001 — нужен текст ошибки для сообщения теста
            outcome.append(repr(exc))

    thread = threading.Thread(target=work)
    thread.start()
    thread.join()
    assert outcome == ["1"], outcome


def test_make_engine_non_sqlite_is_plain_lazy_engine():
    from app.db import make_engine
    engine = make_engine("postgresql+psycopg://localhost/judge")   # подключение не открывается
    assert engine.dialect.name == "postgresql"


def test_foreign_key_violation_rejected_through_make_engine(tmp_path):
    from app.db import make_engine
    engine = make_engine(migrated_url(tmp_path))
    with pytest.raises(sa_exc.IntegrityError):
        with engine.begin() as conn:
            conn.execute(sa.text(INSERT_CRITERION), {"rubric_id": "no-such-rubric"})


INSERT_CRITERION = ("INSERT INTO criterion (id, rubric_id, position, name, weight, max_score, agent) "
                    "VALUES ('C1', :rubric_id, 1, 'Идея', 1.0, 10, 'business')")


def test_control_plain_engine_does_not_enforce_foreign_keys(tmp_path):
    """Контроль: без make_engine SQLite не проверяет FK — значит, тест выше действительно проверяет PRAGMA."""
    engine = sa.create_engine(migrated_url(tmp_path))
    with engine.begin() as conn:
        conn.execute(sa.text(INSERT_CRITERION), {"rubric_id": "no-such-rubric"})


# ─────────────────────────────── сессии ───────────────────────────────

def test_session_factory_does_not_expire_on_commit(tmp_path):
    engine, factory = new_factory(tmp_path)
    assert factory().expire_on_commit is False


def test_session_scope_commits_on_success(tmp_path):
    from app.db import session_scope
    from sqlalchemy.orm import Session
    _, factory = new_factory(tmp_path)
    with session_scope(factory) as s:
        assert isinstance(s, Session)
        add_project(s)
    with session_scope(factory) as other:
        assert count(other, "project") == 1


def test_session_scope_rolls_back_and_reraises_on_error(tmp_path):
    from app.db import session_scope
    _, factory = new_factory(tmp_path)
    with session_scope(factory) as s:
        add_project(s, "P1")
    with pytest.raises(RuntimeError, match="boom"):
        with session_scope(factory) as s:
            add_project(s, "P2")
            raise RuntimeError("boom")
    with session_scope(factory) as other:
        assert count(other, "project") == 1


# ─────────────────────────────── update_versioned ───────────────────────────────

def test_update_versioned_returns_new_version_and_writes_values(tmp_path):
    from app.db import session_scope
    from app.repositories.base import update_versioned
    _, factory = new_factory(tmp_path)
    with session_scope(factory) as s:
        add_project(s)
        assert update_versioned(s, "project", "P1", 1, {"name": "Renamed", "status": "intake"}) == 2
    with session_scope(factory) as s:
        assert tuple(project_row(s)) == ("Renamed", "intake", 2)
        assert update_versioned(s, "project", "P1", 2, {"name": "Again"}) == 3


def test_update_versioned_stale_version_raises_conflict_and_changes_nothing(tmp_path):
    from app.db import session_scope
    from app.repositories.base import VersionConflict, update_versioned
    _, factory = new_factory(tmp_path)
    with session_scope(factory) as s:
        add_project(s)
    with session_scope(factory) as s:
        with pytest.raises(VersionConflict):
            update_versioned(s, "project", "P1", 7, {"name": "Stale"})
        assert tuple(project_row(s)) == ("Demo", "setup", 1)


def test_update_versioned_missing_row_is_lookup_error_not_conflict(tmp_path):
    from app.db import session_scope
    from app.repositories.base import VersionConflict, update_versioned
    _, factory = new_factory(tmp_path)
    with session_scope(factory) as s:
        with pytest.raises(LookupError) as err:
            update_versioned(s, "project", "no-such-id", 1, {"name": "x"})
        assert not isinstance(err.value, VersionConflict)


def test_version_conflict_is_plain_exception():
    from app.repositories.base import VersionConflict
    assert issubclass(VersionConflict, Exception) and not issubclass(VersionConflict, LookupError)


def test_update_versioned_values_are_parameterized(tmp_path):
    from app.db import session_scope
    from app.repositories.base import update_versioned
    _, factory = new_factory(tmp_path)
    evil = "x'); DROP TABLE project;--"
    with session_scope(factory) as s:
        add_project(s)
        update_versioned(s, "project", "P1", 1, {"name": evil})
    with session_scope(factory) as s:
        assert project_row(s).name == evil
        assert count(s, "project") == 1


def test_concurrent_writers_second_gets_version_conflict(tmp_path):
    from app.db import session_scope
    from app.repositories.base import VersionConflict, update_versioned
    _, factory = new_factory(tmp_path)
    with session_scope(factory) as s:
        add_project(s)
    with session_scope(factory) as second:
        expected_second = project_row(second).version          # оба прочитали version=1
        with session_scope(factory) as first:
            expected_first = project_row(first).version
            assert expected_first == expected_second == 1
            assert update_versioned(first, "project", "P1", expected_first, {"name": "first"}) == 2
        with pytest.raises(VersionConflict):
            update_versioned(second, "project", "P1", expected_second, {"name": "second"})
    with session_scope(factory) as s:
        assert tuple(project_row(s)) == ("first", "setup", 2)


# ─────────────────────────────── курсор ───────────────────────────────

def test_cursor_roundtrip_and_url_safe():
    from app.repositories.base import decode_cursor, encode_cursor
    cursor = encode_cursor("2026-01-01 00:00:00.000000", "01HZX-id_1")
    assert isinstance(cursor, str) and re.fullmatch(r"[A-Za-z0-9_=-]+", cursor), cursor
    assert decode_cursor(cursor) == ("2026-01-01 00:00:00.000000", "01HZX-id_1")


def test_cursor_roundtrip_with_unusual_characters():
    from app.repositories.base import decode_cursor, encode_cursor
    created, row_id = "2026-01-01T00:00:00+00:00", "id|with:separators/и юникод"
    assert decode_cursor(encode_cursor(created, row_id)) == (created, row_id)


@pytest.mark.parametrize("garbage", ["", "!!!", "%%%%", "aGVsbG8", "not a cursor", "a" * 5000])
def test_decode_cursor_rejects_garbage(garbage):
    from app.repositories.base import decode_cursor
    with pytest.raises(ValueError):
        decode_cursor(garbage)


def test_decode_cursor_rejects_base64_of_wrong_shape():
    import base64
    from app.repositories.base import decode_cursor
    for payload in (b"hello", b"{}", b"[]", b"\x00\xff\xfe"):
        with pytest.raises(ValueError):
            decode_cursor(base64.urlsafe_b64encode(payload).decode())


# ─────────────────────────────── keyset_page ───────────────────────────────

@pytest.mark.parametrize("limit", [50, 45, 7])
def test_keyset_pages_cover_all_rows_in_order_without_duplicates(tmp_path, limit):
    _, factory = new_factory(tmp_path)
    expected = seed_messages(factory, 120)
    got = all_pages(factory, limit=limit, where="project_id = :pid", params={"pid": "P1"})
    assert len(got) == len(set(got)) == 120, "дубликаты или пропуски"
    assert got == expected, "порядок должен быть (created_at, id) по возрастанию, ничьи — по id"


def test_keyset_first_page_shape_and_cursors(tmp_path):
    from app.db import session_scope
    from app.repositories.base import decode_cursor, keyset_page
    _, factory = new_factory(tmp_path)
    expected = seed_messages(factory, 120)
    with session_scope(factory) as s:
        rows, cursor = keyset_page(s, "message", limit=50, where="project_id = :pid", params={"pid": "P1"})
        assert len(rows) == 50 and all(isinstance(r, dict) for r in rows)
        assert [r["id"] for r in rows] == expected[:50]
        assert cursor is not None and decode_cursor(cursor)[1] == rows[-1]["id"]
        rest, last_cursor = keyset_page(s, "message", limit=200, after=cursor,
                                        where="project_id = :pid", params={"pid": "P1"})
        assert [r["id"] for r in rest] == expected[50:] and last_cursor is None


def test_keyset_exact_remainder_has_no_next_cursor(tmp_path):
    from app.db import session_scope
    from app.repositories.base import keyset_page
    _, factory = new_factory(tmp_path)
    seed_messages(factory, 120)
    with session_scope(factory) as s:
        rows, cursor = keyset_page(s, "message", limit=120, where="project_id = :pid", params={"pid": "P1"})
    assert len(rows) == 120 and cursor is None


def test_keyset_empty_result(tmp_path):
    from app.db import session_scope
    from app.repositories.base import keyset_page
    _, factory = new_factory(tmp_path)
    with session_scope(factory) as s:
        assert keyset_page(s, "message", limit=10) == ([], None)


def test_keyset_insert_between_pages_does_not_shift_or_duplicate(tmp_path):
    from app.db import session_scope
    _, factory = new_factory(tmp_path)
    original = seed_messages(factory, 120)

    def insert_between(page_no, rows, cursor):
        if page_no != 1:
            return
        with session_scope(factory) as s:
            add_message(s, "A000", "2026-01-01 00:00:00.000000")   # раньше курсора: уже «позади»
            add_message(s, "M999", "2026-01-01 00:05:30.000000")   # позже курсора: попадёт в оставшиеся страницы

    got = all_pages(factory, limit=50, where="project_id = :pid", params={"pid": "P1"}, hook=insert_between)
    assert len(got) == len(set(got)), "дубликаты после вставки между страницами"
    assert set(got) == set(original) | {"M999"}, "строка раньше курсора не должна появиться, позже — обязана"
    assert "A000" not in got


@pytest.mark.parametrize("limit", [0, -1, 201, 1000])
def test_keyset_limit_out_of_range_raises(tmp_path, limit):
    from app.db import session_scope
    from app.repositories.base import keyset_page
    _, factory = new_factory(tmp_path)
    with session_scope(factory) as s:
        with pytest.raises(ValueError):
            keyset_page(s, "message", limit=limit)


@pytest.mark.parametrize("limit", [1, 200])
def test_keyset_limit_bounds_accepted(tmp_path, limit):
    from app.db import session_scope
    from app.repositories.base import keyset_page
    _, factory = new_factory(tmp_path)
    seed_messages(factory, 5)
    with session_scope(factory) as s:
        rows, _ = keyset_page(s, "message", limit=limit)
    assert len(rows) == min(limit, 5)


def test_keyset_invalid_after_cursor_raises(tmp_path):
    from app.db import session_scope
    from app.repositories.base import keyset_page
    _, factory = new_factory(tmp_path)
    with session_scope(factory) as s:
        with pytest.raises(ValueError):
            keyset_page(s, "message", limit=10, after="!!!")


def test_keyset_where_params_are_bound_not_interpolated(tmp_path):
    from app.db import session_scope
    from app.repositories.base import keyset_page
    _, factory = new_factory(tmp_path)
    seed_messages(factory, 120)
    with session_scope(factory) as s:
        rows, cursor = keyset_page(s, "message", limit=10, where="project_id = :pid",
                                   params={"pid": "'; DROP TABLE message;--"})
        assert rows == [] and cursor is None
        assert count(s, "message") == 120, "таблица message пережила значение с SQL внутри"


def test_keyset_where_filters_rows(tmp_path):
    from app.db import session_scope
    from app.repositories.base import keyset_page
    _, factory = new_factory(tmp_path)
    seed_messages(factory, 20)
    with session_scope(factory) as s:
        rows, cursor = keyset_page(s, "message", limit=50, where="id >= :low", params={"low": "M015"})
    assert [r["id"] for r in rows] == ["M015", "M016", "M017", "M018", "M019"] and cursor is None


# ─────────────────────────────── интеграция с create_app ───────────────────────────────

DB_ROUTES = '''
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from app.db import get_session
from app.repositories.base import VersionConflict
router = APIRouter()

_INSERT = text("INSERT INTO project (id, name, type, status, agents, required_materials, retention_days, "
               "last_activity_at, version, created_at, updated_at) VALUES (:id, 'n', 'other', 'setup', '[]', '{}', 7, "
               "'2026-01-01 00:00:00.000000', 1, '2026-01-01 00:00:00.000000', '2026-01-01 00:00:00.000000')")

@router.post("/dbt/add")
def add(session=Depends(get_session)):
    session.execute(_INSERT, {"id": "OK1"})
    return {"ok": True}

@router.post("/dbt/add-then-fail")
def add_then_fail(session=Depends(get_session)):
    session.execute(_INSERT, {"id": "BAD1"})
    raise RuntimeError("late failure")

@router.post("/dbt/add-then-400")
def add_then_400(session=Depends(get_session)):
    session.execute(_INSERT, {"id": "BAD2"})
    raise HTTPException(400, "rejected")

@router.get("/dbt/count")
def count(session=Depends(get_session)):
    return {"n": session.execute(text("SELECT count(*) FROM project")).scalar_one()}

@router.get("/dbt/conflict")
def conflict():
    raise VersionConflict("SELECT secret-sql-internals FROM project WHERE version = 3")
'''


def db_app(tmp_path, monkeypatch, *, migrate: bool = True, name: str = "app.db"):
    from app.config import load_settings
    from app.main import create_app
    pkg = f"dbt_{uuid.uuid4().hex[:10]}"
    (tmp_path / pkg).mkdir()
    (tmp_path / pkg / "__init__.py").write_text("")
    (tmp_path / pkg / "routes.py").write_text(textwrap.dedent(DB_ROUTES))
    monkeypatch.syspath_prepend(str(tmp_path))
    url = migrated_url(tmp_path, name) if migrate else f"sqlite:///{tmp_path / name}"
    return create_app(load_settings({"JUDGE_DATABASE_URL": url}), routers_package=pkg)


def client_of(app):
    from fastapi.testclient import TestClient
    return TestClient(app, raise_server_exceptions=False)


def test_create_app_exposes_engine_and_session_factory_lazily(tmp_path, monkeypatch):
    app = db_app(tmp_path, monkeypatch, migrate=False, name="lazy.db")
    assert app.state.engine.url.database.endswith("lazy.db")
    assert callable(app.state.session_factory)
    assert not (tmp_path / "lazy.db").exists(), "create_app не должен подключаться к БД до первого запроса"


def test_lifespan_shutdown_disposes_engine(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient
    from sqlalchemy.engine import Engine
    app = db_app(tmp_path, monkeypatch)
    disposed: list[object] = []
    real = Engine.dispose

    def spy(self, *args, **kwargs):
        disposed.append(self)
        return real(self, *args, **kwargs)

    monkeypatch.setattr(Engine, "dispose", spy)
    with TestClient(app) as client:
        assert client.get("/dbt/count").status_code == 200
        assert app.state.engine not in disposed
    assert app.state.engine in disposed, "на shutdown engine.dispose() не вызван"


def test_get_session_commits_on_success(tmp_path, monkeypatch):
    client = client_of(db_app(tmp_path, monkeypatch))
    assert client.post("/dbt/add").status_code == 200
    assert client.get("/dbt/count").json() == {"n": 1}


def test_get_session_rolls_back_on_unhandled_exception(tmp_path, monkeypatch):
    client = client_of(db_app(tmp_path, monkeypatch))
    assert client.post("/dbt/add-then-fail").status_code == 500
    assert client.get("/dbt/count").json() == {"n": 0}


def test_get_session_rolls_back_on_http_exception(tmp_path, monkeypatch):
    client = client_of(db_app(tmp_path, monkeypatch))
    assert client.post("/dbt/add-then-400").status_code == 400
    assert client.get("/dbt/count").json() == {"n": 0}


def test_version_conflict_maps_to_409_error_format(tmp_path, monkeypatch):
    client = client_of(db_app(tmp_path, monkeypatch))
    resp = client.get("/dbt/conflict", headers={"X-Request-ID": "vc-1"})
    assert resp.status_code == 409
    body = resp.json()
    error_schema = yaml.safe_load(OPENAPI.read_text(encoding="utf-8"))["components"]["schemas"]["Error"]
    jsonschema.validate(body, error_schema)
    assert body["error"]["code"] == "version_conflict"
    assert body["error"]["message"] and "secret-sql-internals" not in resp.text
    assert body["error"]["request_id"] == "vc-1" == resp.headers["X-Request-ID"]
