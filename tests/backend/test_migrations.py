"""T012: Alembic-миграция 0001 по specs/001-ai-judge-platform/data-model.md.

Тесты написаны ДО реализации (RED): backend/alembic.ini и backend/migrations/ появятся в T012.
Проверяется на SQLite (временный файл БД на тест) и офлайн-SQL для PostgreSQL.

Контракт:
- конфиг ``backend/alembic.ini``, скрипты ``backend/migrations/`` (env.py, versions/), одна голова ``0001``;
- URL БД: ``sqlalchemy.url`` из конфигурации Alembic (``Config.set_main_option``), иначе переменная
  ``JUDGE_DATABASE_URL``, иначе ``sqlite:///judge.db`` относительно текущего каталога;
- 15 таблиц данных + ``alembic_version``; уникальности, внешние ключи, частичный уникальный индекс
  «одна активная задача на (submission_id, role)»;
- BEFORE UPDATE / BEFORE DELETE на journal_event и score_override кидают ошибку с ``append-only`` (I-3);
- ``downgrade base`` убирает всё, кроме alembic_version.

Допущения о вставках (data-model.md не говорит об обязательности колонок): строки вставляются
полным набором колонок из data-model.md; недостающие NOT NULL-колонки без default, если они есть,
добираются хелпером ``insert`` только для ``id`` (строковый ULID), ``created_at``/``updated_at``,
``version`` и ``schema_version``. Остальное тест не угадывает: такая вставка упадёт и покажет контракт.

Фикстуры не трогают файлы реализации: всё, что требует миграции, вызывается внутри тестов, поэтому
при отсутствии реализации тесты именно FAILED, а не ERROR.
"""
from __future__ import annotations

import functools
import io
import os
import re
import sqlite3
import subprocess
from pathlib import Path

import pytest
import sqlalchemy as sa
from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import exc as sa_exc

REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / "backend"
INI = BACKEND / "alembic.ini"
MIGRATIONS = BACKEND / "migrations"
MIGRATE_SH = REPO / "scripts" / "migrate.sh"

DATA_TABLES = [
    "project", "brief", "rubric", "criterion", "ux_metrics", "message", "submission", "material",
    "run", "run_task", "criterion_score", "score_override", "flag", "journal_event", "claim",
]
ALL_TABLES = set(DATA_TABLES) | {"alembic_version"}

JOURNAL_COLUMNS = [
    "schema_version", "ts", "project_id", "run_id", "submission_id", "role", "session_id", "seq", "event", "tool",
    "args_summary", "result_summary", "refs", "duration_ms", "model", "provider", "tokens_in",
    "tokens_out", "cost_usd", "actor", "source",
]
EXPECTED_COLUMNS = {
    "project": ["id", "name", "type", "status", "starts_on", "ends_on", "agents", "required_materials",
                "rubric_confirmed_version", "retention_days", "last_activity_at", "version",
                "created_at", "updated_at", "deleted_at"],
    "brief": ["id", "project_id", "name", "source", "status", "reason", "path", "extracted_text_path",
              "created_at", "deleted_at"],
    "rubric": ["id", "project_id", "version", "status", "weights_were_missing", "confirmed_at", "created_at"],
    "criterion": ["id", "rubric_id", "position", "name", "description", "weight", "max_score", "agent",
                  "anchors", "source_ref"],
    "ux_metrics": ["project_id", "metrics", "created_at"],
    "message": ["id", "project_id", "author", "kind", "text", "attachments", "created_at"],
    "submission": ["id", "project_id", "team_name", "intake_status", "completeness", "missing",
                   "inventory_path", "version", "created_at", "deleted_at"],
    "material": ["id", "submission_id", "type", "source_kind", "source_ref", "status", "reason",
                 "size_bytes", "purged_at"],
    "run": ["id", "project_id", "rubric_version", "status", "requested", "tokens_in", "tokens_out",
            "cost_usd", "created_at", "finished_at"],
    "run_task": ["id", "run_id", "submission_id", "role", "state", "attempt", "reason", "hermes_run_id",
                 "started_at", "finished_at", "tokens_in", "tokens_out", "cost_usd", "model", "provider"],
    "criterion_score": ["id", "run_task_id", "submission_id", "criterion_id", "rubric_version", "status",
                        "score", "max_score", "justification", "evidence", "confidence", "no_data_reason",
                        "version", "created_at"],
    "score_override": ["id", "criterion_score_id", "submission_id", "criterion_id", "score", "reason",
                       "actor", "created_at"],
    "flag": ["id", "run_task_id", "submission_id", "criterion_id", "type", "confidence", "note", "evidence",
             "related_submission_id", "related_url", "created_at"],
    "journal_event": JOURNAL_COLUMNS,
    "claim": ["id", "run_task_id", "claim_id", "text", "source_ref", "verdict", "evidence"],
}

# Первичные ключи таблиц с суррогатным id (journal_event в список не входит: его ключ — решение реализации).
PK_COLUMNS = {t: ["id"] for t in DATA_TABLES if t not in ("ux_metrics", "journal_event")}
PK_COLUMNS["ux_metrics"] = ["project_id"]

NOT_NULL = {
    "project": ["name", "type", "status", "version", "created_at", "updated_at"],
    "run_task": ["run_id", "role", "state"],
    "criterion_score": ["run_task_id", "submission_id", "criterion_id", "status", "version", "created_at"],
    "journal_event": ["schema_version", "ts", "project_id", "run_id", "seq", "event", "source"],
}
NULLABLE = {
    "project": ["deleted_at"],
    "run_task": ["submission_id", "reason", "hermes_run_id", "started_at", "finished_at", "tokens_in",
                 "tokens_out", "cost_usd", "model", "provider"],
    "criterion_score": ["score", "no_data_reason"],
    "journal_event": ["submission_id", "role", "session_id", "tool", "args_summary", "result_summary",
                      "duration_ms", "model", "provider", "tokens_in", "tokens_out", "cost_usd", "actor"],
}
INTEGER_COLUMNS = [("project", "version"), ("project", "retention_days"), ("run_task", "attempt"),
                   ("criterion_score", "version"), ("journal_event", "seq"), ("journal_event", "duration_ms"),
                   ("journal_event", "tokens_in"), ("journal_event", "tokens_out")]
NUMERIC_COLUMNS = [("run_task", "cost_usd"), ("criterion_score", "score"), ("journal_event", "cost_usd")]

UNIQUE_SETS = [
    ("rubric", {"project_id", "version"}),
    ("submission", {"project_id", "team_name"}),
    ("journal_event", {"run_id", "seq"}),
]
FOREIGN_KEYS = [
    ("criterion", "rubric_id", "rubric"),
    ("run_task", "run_id", "run"),
    ("criterion_score", "run_task_id", "run_task"),
    ("score_override", "criterion_score_id", "criterion_score"),
    ("material", "submission_id", "submission"),
]

TS = "2026-01-01 00:00:00"
# Полные строки по data-model.md (id — стабильные короткие строки; в проде ULID).
ROWS = {
    "project": dict(id="P1", name="Demo", type="product_hackathon", status="setup", starts_on="2026-01-01",
                    ends_on="2026-01-02", agents='["code"]', required_materials="[]", retention_days=7,
                    last_activity_at=TS, version=1, created_at=TS, updated_at=TS),
    "rubric": dict(id="R1", project_id="P1", version=1, status="draft", weights_were_missing=0, created_at=TS),
    "criterion": dict(id="C1", rubric_id="R1", position=1, name="Идея", description="d", weight=1.0,
                      max_score=10, agent="business", anchors="{}", source_ref="brief"),
    "submission": dict(id="S1", project_id="P1", team_name="Team A", intake_status="ready",
                       completeness="complete", missing="[]", inventory_path="s1/inventory.json",
                       version=1, created_at=TS),
    "run": dict(id="RUN1", project_id="P1", rubric_version=1, status="queued", requested="{}",
                created_at=TS),
    "run_task": dict(id="T1", run_id="RUN1", submission_id="S1", role="code", state="queued", attempt=1),
    "criterion_score": dict(id="CS1", run_task_id="T1", submission_id="S1", criterion_id="C1",
                            rubric_version=1, status="scored", score=7, max_score=10, justification="ok",
                            evidence="[]", confidence=0.8, version=1, created_at=TS),
    "score_override": dict(id="SO1", criterion_score_id="CS1", submission_id="S1", criterion_id="C1",
                           score=9, reason="r", actor="demo", created_at=TS),
    "journal_event": dict(ts=TS, project_id="P1", run_id="RUN1", seq=0, event="run_started", source="backend"),
}


# ─────────────────────────────── хелперы ───────────────────────────────

def make_cfg(url: str | None = None) -> Config:
    cfg = Config(str(INI))
    cfg.set_main_option("script_location", str(MIGRATIONS))
    if url is not None:
        cfg.set_main_option("sqlalchemy.url", url)
    return cfg


def sqlite_url(path: Path) -> str:
    return f"sqlite:///{path}"


def upgraded(tmp_path: Path) -> sa.Engine:
    """SQLite-файл в tmp_path, на который накатан head. Вызывается внутри теста (не фикстурой)."""
    url = sqlite_url(tmp_path / "judge.db")
    command.upgrade(make_cfg(url), "head")
    return sa.create_engine(url)


def table_names(engine: sa.Engine) -> set[str]:
    return set(sa.inspect(engine).get_table_names())


_ULID_SEQ = iter(range(1, 10**9))


def insert(conn: sa.Connection, table: str, *, verb: str = "INSERT", **over) -> None:
    """``verb`` INSERT полной строки из ROWS[table] с переопределениями; недостающие NOT NULL-колонки — см. docstring модуля."""
    values = {**ROWS.get(table, {}), **over}
    cols = {c["name"]: c for c in sa.inspect(conn).get_columns(table)}
    unknown = sorted(set(values) - set(cols))
    assert not unknown, f"в таблице {table} нет колонок {unknown} (data-model.md)"
    for name, col in cols.items():
        if name in values or col["nullable"] or col.get("default") is not None:
            continue
        if name == "id" and isinstance(col["type"], sa.String):
            values[name] = f"AUTO{next(_ULID_SEQ):020d}"
        elif name in ("created_at", "updated_at"):
            values[name] = TS
        elif name == "version":
            values[name] = 1
        elif name == "schema_version":
            values[name] = "1"
    names = ", ".join(f'"{n}"' for n in values)
    params = ", ".join(f":{n}" for n in values)
    conn.execute(sa.text(f'{verb} INTO "{table}" ({names}) VALUES ({params})'), values)


def seed_chain(conn: sa.Connection) -> None:
    """project → rubric → criterion → submission → run → run_task(T1, queued) → criterion_score."""
    for table in ("project", "rubric", "criterion", "submission", "run", "run_task", "criterion_score"):
        insert(conn, table)


def count(conn: sa.Connection, table: str) -> int:
    return conn.execute(sa.text(f'SELECT count(*) FROM "{table}"')).scalar_one()


def snapshot(conn: sa.Connection, table: str) -> list[tuple]:
    return [tuple(r) for r in conn.execute(sa.text(f'SELECT * FROM "{table}" ORDER BY 1, 2')).all()]


def unique_sets(insp: sa.Inspector, table: str) -> list[frozenset]:
    out = [frozenset(u["column_names"]) for u in insp.get_unique_constraints(table)]
    out += [frozenset(i["column_names"]) for i in insp.get_indexes(table) if i.get("unique")]
    out.append(frozenset(insp.get_pk_constraint(table)["constrained_columns"]))
    return out


# ─────────────────────── 1. конфиг и ревизии ───────────────────────

def test_alembic_ini_and_scripts_exist():
    assert INI.is_file(), f"нет {INI}"
    assert (MIGRATIONS / "env.py").is_file(), "нет backend/migrations/env.py"
    assert (MIGRATIONS / "versions").is_dir(), "нет backend/migrations/versions/"


def test_single_head_is_0001():
    heads = ScriptDirectory.from_config(make_cfg()).get_heads()
    assert heads == ["0001"], f"ожидалась одна голова 0001, есть {heads}"


# ─────────────────────── 2. схема после upgrade head ───────────────────────

def test_upgrade_creates_exactly_expected_tables(tmp_path):
    engine = upgraded(tmp_path)
    assert table_names(engine) == ALL_TABLES


@pytest.mark.parametrize("table", DATA_TABLES)
def test_table_has_data_model_columns(tmp_path, table):
    engine = upgraded(tmp_path)
    actual = {c["name"] for c in sa.inspect(engine).get_columns(table)}
    missing = [c for c in EXPECTED_COLUMNS[table] if c not in actual]
    assert not missing, f"{table}: нет колонок {missing}"


@pytest.mark.parametrize("table", sorted(PK_COLUMNS))
def test_primary_keys(tmp_path, table):
    engine = upgraded(tmp_path)
    assert sa.inspect(engine).get_pk_constraint(table)["constrained_columns"] == PK_COLUMNS[table]


@pytest.mark.parametrize("table", sorted(NOT_NULL))
def test_not_null_columns(tmp_path, table):
    engine = upgraded(tmp_path)
    cols = {c["name"]: c for c in sa.inspect(engine).get_columns(table)}
    for name in NOT_NULL[table]:
        assert name in cols, f"{table}.{name}: колонки нет"
        assert cols[name]["nullable"] is False, f"{table}.{name} должна быть NOT NULL"


@pytest.mark.parametrize("table", sorted(NULLABLE))
def test_nullable_columns(tmp_path, table):
    engine = upgraded(tmp_path)
    cols = {c["name"]: c for c in sa.inspect(engine).get_columns(table)}
    for name in NULLABLE[table]:
        assert name in cols, f"{table}.{name}: колонки нет"
        assert cols[name]["nullable"] is True, f"{table}.{name} должна допускать NULL"


def test_column_types_integer_and_numeric(tmp_path):
    engine = upgraded(tmp_path)
    insp = sa.inspect(engine)
    for table, name in INTEGER_COLUMNS:
        col = {c["name"]: c for c in insp.get_columns(table)}[name]
        assert isinstance(col["type"], sa.Integer), f"{table}.{name}: ожидался INTEGER, есть {col['type']}"
    for table, name in NUMERIC_COLUMNS:
        col = {c["name"]: c for c in insp.get_columns(table)}[name]
        assert isinstance(col["type"], (sa.Numeric, sa.Float, sa.Integer)), f"{table}.{name}: ожидалось число, есть {col['type']}"


@pytest.mark.parametrize("table,columns", UNIQUE_SETS, ids=[t for t, _ in UNIQUE_SETS])
def test_unique_constraints_declared(tmp_path, table, columns):
    engine = upgraded(tmp_path)
    assert frozenset(columns) in unique_sets(sa.inspect(engine), table)


@pytest.mark.parametrize("table,column,ref_table", FOREIGN_KEYS, ids=[f"{t}.{c}" for t, c, _ in FOREIGN_KEYS])
def test_foreign_keys_declared(tmp_path, table, column, ref_table):
    engine = upgraded(tmp_path)
    fks = sa.inspect(engine).get_foreign_keys(table)
    assert any(f["constrained_columns"] == [column] and f["referred_table"] == ref_table
               and f["referred_columns"] == ["id"] for f in fks), f"нет FK {table}.{column} → {ref_table}.id: {fks}"


def test_journal_event_minimal_insert_uses_only_required_fields(tmp_path):
    """Обязательны только поля контракта journal-event.schema.json; остальные — NULL (или default)."""
    engine = upgraded(tmp_path)
    with engine.begin() as conn:
        conn.execute(sa.text(
            "INSERT INTO journal_event (ts, project_id, run_id, seq, event, source) "
            "VALUES (:ts, 'P1', 'RUN1', 0, 'run_started', 'backend')"), {"ts": TS})
        assert count(conn, "journal_event") == 1


def test_journal_event_schema_version_defaults_to_1(tmp_path):
    """schema_version (const "1" в journal-event.schema.json) обязателен, но берётся из серверного default."""
    engine = upgraded(tmp_path)
    with engine.begin() as conn:
        conn.execute(sa.text(
            "INSERT INTO journal_event (ts, project_id, run_id, seq, event, source) "
            "VALUES (:ts, 'P1', 'RUN1', 0, 'run_started', 'backend')"), {"ts": TS})
        value = conn.execute(sa.text("SELECT schema_version FROM journal_event")).scalar_one()
    assert str(value) == "1" and isinstance(value, str), f"schema_version = {value!r}, ожидалась строка '1'"


# ─────────────────────── 2b. уникальности на данных ───────────────────────

def test_rubric_version_unique_per_project(tmp_path):
    engine = upgraded(tmp_path)
    with engine.begin() as conn:
        insert(conn, "project")
        insert(conn, "rubric")
    with pytest.raises(sa_exc.IntegrityError):
        with engine.begin() as conn:
            insert(conn, "rubric", id="R2")
    with engine.begin() as conn:
        insert(conn, "rubric", id="R3", version=2)
        assert count(conn, "rubric") == 2


def test_submission_team_unique_per_project(tmp_path):
    engine = upgraded(tmp_path)
    with engine.begin() as conn:
        insert(conn, "project")
        insert(conn, "submission")
    with pytest.raises(sa_exc.IntegrityError):
        with engine.begin() as conn:
            insert(conn, "submission", id="S2")
    with engine.begin() as conn:
        insert(conn, "submission", id="S3", team_name="Team B")
        assert count(conn, "submission") == 2


def test_journal_event_run_seq_unique(tmp_path):
    engine = upgraded(tmp_path)
    with engine.begin() as conn:
        insert(conn, "journal_event")
    with pytest.raises(sa_exc.IntegrityError):
        with engine.begin() as conn:
            insert(conn, "journal_event")
    with engine.begin() as conn:
        insert(conn, "journal_event", seq=1)
        assert count(conn, "journal_event") == 2


# ─────────────────────── 3. частичный уникальный индекс run_task ───────────────────────

def _chain_for_tasks(engine: sa.Engine) -> None:
    with engine.begin() as conn:
        for table in ("project", "submission", "run"):
            insert(conn, table)


@pytest.mark.parametrize("first,second", [("queued", "queued"), ("queued", "running"),
                                          ("running", "queued"), ("running", "running")])
def test_two_active_tasks_for_same_submission_and_role_rejected(tmp_path, first, second):
    engine = upgraded(tmp_path)
    _chain_for_tasks(engine)
    with engine.begin() as conn:
        insert(conn, "run_task", id="T1", state=first)
    with pytest.raises(sa_exc.IntegrityError):
        with engine.begin() as conn:
            insert(conn, "run_task", id="T2", state=second)
    with engine.connect() as conn:
        assert count(conn, "run_task") == 1


def test_second_active_task_allowed_after_first_is_done(tmp_path):
    engine = upgraded(tmp_path)
    _chain_for_tasks(engine)
    with engine.begin() as conn:
        insert(conn, "run_task", id="T1", state="running")
    with engine.begin() as conn:
        conn.execute(sa.text("UPDATE run_task SET state = 'done' WHERE id = 'T1'"))
        insert(conn, "run_task", id="T2", state="queued")
        assert count(conn, "run_task") == 2


def test_several_done_tasks_for_same_submission_and_role_allowed(tmp_path):
    engine = upgraded(tmp_path)
    _chain_for_tasks(engine)
    with engine.begin() as conn:
        insert(conn, "run_task", id="T1", state="done")
        insert(conn, "run_task", id="T2", state="done")
        insert(conn, "run_task", id="T3", state="failed")
        insert(conn, "run_task", id="T4", state="queued")
        assert count(conn, "run_task") == 4


def test_active_tasks_for_different_role_or_submission_allowed(tmp_path):
    engine = upgraded(tmp_path)
    _chain_for_tasks(engine)
    with engine.begin() as conn:
        insert(conn, "submission", id="S2", team_name="Team B")
        insert(conn, "run_task", id="T1", state="queued")
        insert(conn, "run_task", id="T2", state="queued", role="design")
        insert(conn, "run_task", id="T3", state="queued", submission_id="S2")
        assert count(conn, "run_task") == 3


# ─────────────────────── 4. append-only (I-3) ───────────────────────

APPEND_ONLY = {
    "journal_event": dict(
        update="UPDATE journal_event SET result_summary = 'tampered' WHERE run_id = 'RUN1' AND seq = 0",
        delete="DELETE FROM journal_event WHERE run_id = 'RUN1' AND seq = 0",
        insert=lambda conn: insert(conn, "journal_event", seq=1),
    ),
    "score_override": dict(
        update="UPDATE score_override SET score = 1 WHERE id = 'SO1'",
        delete="DELETE FROM score_override WHERE id = 'SO1'",
        insert=lambda conn: insert(conn, "score_override", id="SO2", score=5),
    ),
}


def _seed_append_only(engine: sa.Engine) -> None:
    with engine.begin() as conn:
        seed_chain(conn)
        insert(conn, "score_override")
        insert(conn, "journal_event")


@pytest.mark.parametrize("table", sorted(APPEND_ONLY))
@pytest.mark.parametrize("op", ["update", "delete"])
def test_append_only_rejects_update_and_delete(tmp_path, table, op):
    engine = upgraded(tmp_path)
    _seed_append_only(engine)
    with engine.connect() as conn:
        before = snapshot(conn, table)
    assert len(before) == 1
    with pytest.raises(sa_exc.DBAPIError) as err:
        with engine.begin() as conn:
            conn.execute(sa.text(APPEND_ONLY[table][op]))
    assert "append-only" in str(err.value)
    with engine.connect() as conn:
        assert snapshot(conn, table) == before, "строка изменилась после отклонённой попытки"


# Строка с тем же ключом, но другим значением: INSERT OR REPLACE в SQLite удаляет старую строку, не вызывая
# DELETE-триггер (recursive_triggers=OFF), т.е. журнал или правку можно подменить в обход I-3.
REPLACE_OVERRIDES = {
    "journal_event": dict(result_summary="tampered"),   # тот же (run_id, seq)
    "score_override": dict(score=1),                    # тот же id
}


@pytest.mark.parametrize("table", sorted(APPEND_ONLY))
def test_append_only_rejects_insert_or_replace(tmp_path, table):
    engine = upgraded(tmp_path)
    _seed_append_only(engine)
    with engine.connect() as conn:
        before = snapshot(conn, table)
    assert len(before) == 1
    with pytest.raises(sa_exc.DBAPIError) as err:
        with engine.begin() as conn:
            insert(conn, table, verb="INSERT OR REPLACE", **REPLACE_OVERRIDES[table])
    assert "append-only" in str(err.value)
    with engine.connect() as conn:
        assert snapshot(conn, table) == before, "строка подменена через INSERT OR REPLACE"


@pytest.mark.parametrize("table", sorted(APPEND_ONLY))
def test_append_only_allows_insert(tmp_path, table):
    engine = upgraded(tmp_path)
    _seed_append_only(engine)
    with engine.begin() as conn:
        APPEND_ONLY[table]["insert"](conn)
        assert count(conn, table) == 2


def test_other_tables_are_not_append_only(tmp_path):
    """Триггеры только на двух таблицах: criterion_score изменяем (version +1, I-15), run_task — тоже."""
    engine = upgraded(tmp_path)
    with engine.begin() as conn:
        seed_chain(conn)
        conn.execute(sa.text("UPDATE criterion_score SET score = 8, version = 2 WHERE id = 'CS1'"))
        conn.execute(sa.text("UPDATE run_task SET state = 'running' WHERE id = 'T1'"))
        assert conn.execute(sa.text("SELECT score FROM criterion_score WHERE id = 'CS1'")).scalar_one() == 8


# ─────────────────────── 5. откат и повторный накат ───────────────────────

def test_downgrade_base_leaves_only_alembic_version_then_upgrade_again(tmp_path):
    url = sqlite_url(tmp_path / "judge.db")
    cfg = make_cfg(url)
    command.upgrade(cfg, "head")
    engine = sa.create_engine(url)
    assert table_names(engine) == ALL_TABLES

    command.downgrade(cfg, "base")
    assert table_names(sa.create_engine(url)) == {"alembic_version"}
    with sa.create_engine(url).connect() as conn:
        left = conn.execute(sa.text(
            "SELECT type, name FROM sqlite_master WHERE type IN ('index', 'trigger') "
            "AND name NOT LIKE 'sqlite~_%' ESCAPE '~'")).all()
    assert left == [], f"после downgrade остались индексы/триггеры: {left}"

    command.upgrade(cfg, "head")
    assert table_names(sa.create_engine(url)) == ALL_TABLES
    _seed_append_only(sa.create_engine(url))   # триггеры и индексы вернулись: схема рабочая


# ─────────────────────── 6. источник URL БД ───────────────────────

def test_env_var_used_when_config_url_not_set(tmp_path, monkeypatch):
    db = tmp_path / "from_env.db"
    monkeypatch.setenv("JUDGE_DATABASE_URL", sqlite_url(db))
    command.upgrade(make_cfg(), "head")
    assert table_names(sa.create_engine(sqlite_url(db))) == ALL_TABLES


def test_config_url_wins_over_env_var(tmp_path, monkeypatch):
    env_db, cfg_db = tmp_path / "env.db", tmp_path / "cfg.db"
    monkeypatch.setenv("JUDGE_DATABASE_URL", sqlite_url(env_db))
    command.upgrade(make_cfg(sqlite_url(cfg_db)), "head")
    assert table_names(sa.create_engine(sqlite_url(cfg_db))) == ALL_TABLES
    assert not env_db.exists() or table_names(sa.create_engine(sqlite_url(env_db))) == set()


def test_default_url_is_judge_db_in_current_directory(tmp_path, monkeypatch):
    monkeypatch.delenv("JUDGE_DATABASE_URL", raising=False)
    monkeypatch.chdir(tmp_path)
    command.upgrade(make_cfg(), "head")
    assert (tmp_path / "judge.db").is_file()
    assert table_names(sa.create_engine(sqlite_url(tmp_path / "judge.db"))) == ALL_TABLES


# ─────────────────────── 7. офлайн-SQL PostgreSQL ───────────────────────

PG_URL = "postgresql://localhost/judge"


@functools.lru_cache(maxsize=None)
def pg_sql(direction: str) -> str:
    cfg = make_cfg(PG_URL)
    cfg.output_buffer = io.StringIO()
    if direction == "up":
        command.upgrade(cfg, "head", sql=True)
    else:
        command.downgrade(cfg, "0001:base", sql=True)
    return cfg.output_buffer.getvalue()


def _trigger_statements(sql: str, table: str) -> list[str]:
    stmts = re.findall(r"CREATE\s+(?:OR\s+REPLACE\s+)?TRIGGER\b[^;]*;", sql, re.I | re.S)
    return [s for s in stmts if re.search(rf'\bON\s+"?{table}"?(?=[\s;])', s, re.I)]


@pytest.mark.parametrize("table", DATA_TABLES)
def test_pg_offline_creates_table(table):
    assert re.search(rf'CREATE\s+TABLE\s+"?{table}"?\s*\(', pg_sql("up"), re.I), f"нет CREATE TABLE {table}"


@pytest.mark.parametrize("table", ["journal_event", "score_override"])
@pytest.mark.parametrize("op", ["UPDATE", "DELETE", "TRUNCATE"])
def test_pg_offline_append_only_trigger(table, op):
    """TRUNCATE не запускает построчные триггеры, поэтому для него нужен отдельный statement-level триггер."""
    stmts = _trigger_statements(pg_sql("up"), table)
    if op == "TRUNCATE":
        stmts = [s for s in stmts if re.search(r"\bFOR\s+EACH\s+STATEMENT\b", s, re.I)]
    assert any(re.search(rf"\bBEFORE\b[^;]*\b{op}\b", s, re.I | re.S) for s in stmts), \
        f"нет CREATE TRIGGER BEFORE {op} ON {table}" \
        f"{' FOR EACH STATEMENT' if op == 'TRUNCATE' else ''}; найдено: {stmts}"


def test_pg_offline_raises_append_only_exception():
    assert re.search(r"RAISE\s+EXCEPTION[^;]*append-only", pg_sql("up"), re.I | re.S)


def test_pg_offline_partial_unique_index_on_run_task():
    pattern = (r"CREATE\s+UNIQUE\s+INDEX[^;]*\bON\s+\"?run_task\"?[^;]*\bWHERE\b[^;]*'queued'[^;]*'running'")
    assert re.search(pattern, pg_sql("up"), re.I | re.S), "нет частичного уникального индекса run_task"


@pytest.mark.parametrize("table", ["journal_event", "score_override"])
def test_pg_offline_downgrade_drops_truncate_trigger(table):
    pattern = rf'DROP\s+TRIGGER\s+(?:IF\s+EXISTS\s+)?"?\w*no_truncate"?\s+ON\s+"?{table}"?'
    assert re.search(pattern, pg_sql("down"), re.I), f"нет DROP TRIGGER *no_truncate ON {table}"


def test_pg_offline_downgrade_range_drops_triggers_and_tables():
    sql = pg_sql("down")
    assert re.search(r"DROP\s+TRIGGER", sql, re.I), "нет DROP TRIGGER"
    for table in DATA_TABLES:
        assert re.search(rf'DROP\s+TABLE\s+"?{table}"?', sql, re.I), f"нет DROP TABLE {table}"


# ─────────────────────── 8. scripts/migrate.sh вживую ───────────────────────

def _migrate(tmp_path: Path, *args: str) -> subprocess.CompletedProcess:
    env = {**os.environ, "JUDGE_DATABASE_URL": sqlite_url(tmp_path / "x.db")}
    return subprocess.run(["bash", str(MIGRATE_SH), *args], cwd=REPO, env=env,
                          capture_output=True, text=True, timeout=180)


def _sqlite_tables(path: Path) -> set[str]:
    if not path.exists():
        return set()
    con = sqlite3.connect(path)
    try:
        return {r[0] for r in con.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite~_%' ESCAPE '~'")}
    finally:
        con.close()


def test_migrate_sh_upgrade_then_downgrade_base(tmp_path):
    up = _migrate(tmp_path)
    assert up.returncode == 0, f"migrate.sh upgrade head: {up.stdout}\n{up.stderr}"
    assert "alembic.ini отсутствует" not in up.stderr
    assert _sqlite_tables(tmp_path / "x.db") == ALL_TABLES

    down = _migrate(tmp_path, "downgrade", "base")
    assert down.returncode == 0, f"migrate.sh downgrade base: {down.stdout}\n{down.stderr}"
    assert _sqlite_tables(tmp_path / "x.db") == {"alembic_version"}
