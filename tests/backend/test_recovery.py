"""Восстановление фоновой работы после перезапуска (``app.services.recovery``). Тесты написаны ДО реализации (RED).

Контракт:
- ``recover_interrupted_work(session_factory) -> {"briefs": n, "submissions": n, "run_tasks": n, "runs": n}``:
  (а) ``brief.status='processing'`` -> ``failed`` с ``reason='прервано перезапуском'``;
  (б) ``submission.intake_status IN ('pending','running')`` -> ``failed`` (материалы и остальное не трогать);
  (в) делегирует ``app.services.orchestrator.recover_interrupted(session_factory)`` (прогоны ``queued|running`` и их
  активные задачи -> ``failed``); проект из ``evaluating`` возвращается в ``results``, если у него есть хотя бы один
  ``criterion_score``, иначе в ``intake``; проекты в других статусах не меняются; затрагиваются ВСЕ записи, в том числе
  мягко удалённые; повторный вызов даёт нули;
- ``create_app`` вызывает восстановление в lifespan при старте; ошибка восстановления не роняет старт (ERROR в лог).

Допущения теста:
- в данных у каждого прогона ровно по одной активной задаче, поэтому ``run_tasks`` и ``runs`` совпадают при любом из двух
  прочтений «что возвращает оркестратор» (число прогонов или число задач); различать их тест не пытается;
- ``main.py`` и ``recovery.py`` обращаются к функциям через атрибут модуля (``recovery.recover_interrupted_work(...)``,
  ``orchestrator.recover_interrupted(...)``), иначе ``monkeypatch.setattr`` на модуль не сработает;
- «одна транзакция» проверена наблюдаемо: если делегированное восстановление прогонов падает, исключение выходит наружу, а
  ни брифы, ни работы не изменены.

Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import logging
from pathlib import Path

import pytest
import sqlalchemy as sa
from alembic import command
from alembic.config import Config

REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / "backend"
TS = "2026-01-01 00:00:00.000000"
REASON = "прервано перезапуском"
OLD_REASON = "прежняя причина"
P1, P2, P3, P4, P5 = (f"PROJ00000000000000000000{i:02d}" for i in range(1, 6))
EXPECTED_COUNTS = {"briefs": 3, "submissions": 4, "run_tasks": 2, "runs": 2}


@pytest.fixture(autouse=True)
def restore_root_logger():
    root = logging.getLogger()
    handlers, level = root.handlers[:], root.level
    yield
    root.handlers[:] = handlers
    root.setLevel(level)


def migrated_url(tmp_path: Path) -> str:
    url = f"sqlite:///{tmp_path / 'db.sqlite'}"
    cfg = Config(str(BACKEND / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND / "migrations"))
    cfg.set_main_option("sqlalchemy.url", url)
    command.upgrade(cfg, "head")
    return url


class Env:
    def __init__(self, tmp_path: Path, *, seed: bool = True):
        from app.db import make_engine, make_session_factory
        self.url = migrated_url(tmp_path)
        self.engine = make_engine(self.url)
        self.factory = make_session_factory(self.engine)
        if seed:
            self.seed()

    def sql(self, statement: str, **params) -> None:
        with self.engine.begin() as conn:
            conn.execute(sa.text(statement), params)

    def rows(self, statement: str, **params) -> list[dict]:
        with self.engine.connect() as conn:
            return [dict(r) for r in conn.execute(sa.text(statement), params).mappings()]

    def one(self, table: str, row_id: str) -> dict:
        return self.rows(f"SELECT * FROM {table} WHERE id = :i", i=row_id)[0]

    def seed(self) -> None:
        for pid, status in ((P1, "evaluating"), (P2, "evaluating"), (P3, "setup"), (P4, "results"), (P5, "intake")):
            self.sql("INSERT INTO project (id, name, type, status, agents, required_materials, retention_days, "
                     "last_activity_at, version, created_at, updated_at) "
                     "VALUES (:id, 'Demo', 'other', :status, '[]', '[]', 7, :ts, 1, :ts, :ts)",
                     id=pid, status=status, ts=TS)
        for bid, pid, status, reason, deleted in (
                ("B1", P1, "processing", None, None), ("B2", P1, "processing", None, TS),
                ("B3", P1, "extracted", None, None), ("B4", P1, "failed", OLD_REASON, None),
                ("B5", P3, "processing", None, None), ("B6", P1, "deleted", None, TS)):
            self.sql("INSERT INTO brief (id, project_id, name, source, status, reason, created_at, deleted_at) "
                     "VALUES (:id, :p, :id, 'upload', :status, :reason, :ts, :deleted)",
                     id=bid, p=pid, status=status, reason=reason, ts=TS, deleted=deleted)
        for sid, pid, intake, deleted in (
                ("S1", P1, "pending", None), ("S2", P1, "running", None), ("S3", P1, "ready", None),
                ("S4", P2, "ready", None), ("S5", P1, "pending", TS), ("S6", P5, "pending", None),
                ("S7", P1, "failed", None)):
            self.sql("INSERT INTO submission (id, project_id, team_name, intake_status, version, created_at, "
                     "deleted_at) VALUES (:id, :p, :id, :intake, 1, :ts, :deleted)",
                     id=sid, p=pid, intake=intake, ts=TS, deleted=deleted)
        for mid, sid, status in (("M1", "S1", "available"), ("M2", "S2", "partial")):
            self.sql("INSERT INTO material (id, submission_id, type, source_kind, source_ref, status) "
                     "VALUES (:id, :s, 'document', 'upload', 'file.pdf', :status)", id=mid, s=sid, status=status)
        for rid, pid, status in (("R1", P1, "queued"), ("R2", P2, "running"), ("R3", P1, "completed"),
                                 ("R4", P4, "failed")):
            self.sql("INSERT INTO run (id, project_id, rubric_version, status, created_at) "
                     "VALUES (:id, :p, 1, :status, :ts)", id=rid, p=pid, status=status, ts=TS)
        for tid, rid, sid, role, state in (("T1", "R1", "S3", "code", "queued"),
                                           ("T2", "R2", "S4", "business", "running"),
                                           ("T3", "R3", "S3", "design", "done")):
            self.sql("INSERT INTO run_task (id, run_id, submission_id, role, state, attempt) "
                     "VALUES (:id, :r, :s, :role, :state, 1)", id=tid, r=rid, s=sid, role=role, state=state)
        # у проекта P1 уже есть оценка, у P2 — нет
        self.sql("INSERT INTO criterion_score (id, run_task_id, submission_id, criterion_id, rubric_version, status, "
                 "score, max_score, version, created_at) VALUES ('CS1', 'T3', 'S3', 'C1', 1, 'scored', 7, 10, 1, :ts)",
                 ts=TS)

    def recover(self) -> dict:
        from app.services import recovery
        return recovery.recover_interrupted_work(self.factory)

    def snapshot(self) -> dict:
        return {t: self.rows(f"SELECT * FROM {t} ORDER BY id")
                for t in ("project", "brief", "submission", "material", "run", "run_task", "criterion_score")}


@pytest.fixture
def env(tmp_path):
    return Env(tmp_path)


# ─────────────────────────────── функция восстановления ───────────────────────────────

def test_returns_counters_for_all_four_kinds(env):
    counts = env.recover()
    assert counts == EXPECTED_COUNTS
    assert all(isinstance(v, int) for v in counts.values())


def test_processing_briefs_become_failed_with_reason_including_deleted(env):
    env.recover()
    for brief_id in ("B1", "B2", "B5"):
        brief = env.one("brief", brief_id)
        assert brief["status"] == "failed" and brief["reason"] == REASON, brief_id
    assert env.one("brief", "B2")["deleted_at"] is not None, "мягко удалённая запись остаётся удалённой"


def test_other_briefs_are_untouched(env):
    before = {b: env.one("brief", b) for b in ("B3", "B4", "B6")}
    env.recover()
    assert {b: env.one("brief", b) for b in before} == before
    assert env.one("brief", "B4")["reason"] == OLD_REASON


def test_pending_and_running_submissions_become_failed_including_deleted(env):
    env.recover()
    for sid in ("S1", "S2", "S5", "S6"):
        assert env.one("submission", sid)["intake_status"] == "failed", sid
    assert env.one("submission", "S5")["deleted_at"] is not None


def test_other_submissions_and_materials_are_untouched(env):
    before_subs = {s: env.one("submission", s) for s in ("S3", "S4", "S7")}
    before_materials = env.rows("SELECT * FROM material ORDER BY id")
    env.recover()
    assert {s: env.one("submission", s) for s in before_subs} == before_subs
    assert env.rows("SELECT * FROM material ORDER BY id") == before_materials
    other_fields = env.one("submission", "S1")
    assert other_fields["team_name"] == "S1" and other_fields["version"] == 1 and other_fields["project_id"] == P1


def test_active_runs_and_tasks_become_failed_finished_work_stays(env):
    env.recover()
    for run_id in ("R1", "R2"):
        run = env.one("run", run_id)
        assert run["status"] == "failed" and run["finished_at"] is not None, run_id
    for task_id in ("T1", "T2"):
        task = env.one("run_task", task_id)
        assert task["state"] == "failed" and task["reason"] == "interrupted", task_id
    assert env.one("run", "R3")["status"] == "completed" and env.one("run", "R4")["status"] == "failed"
    assert env.one("run_task", "T3")["state"] == "done"
    assert len(env.rows("SELECT id FROM criterion_score")) == 1


def test_evaluating_project_goes_to_results_with_scores_else_to_intake(env):
    env.recover()
    status = {p: env.one("project", p)["status"] for p in (P1, P2, P3, P4, P5)}
    assert status == {P1: "results", P2: "intake", P3: "setup", P4: "results", P5: "intake"}


def test_second_call_is_idempotent_and_returns_zeros(env):
    env.recover()
    after_first = env.snapshot()
    assert env.recover() == {"briefs": 0, "submissions": 0, "run_tasks": 0, "runs": 0}
    assert env.snapshot() == after_first


def test_clean_database_gives_zeros(tmp_path):
    clean = Env(tmp_path, seed=False)
    assert clean.recover() == {"briefs": 0, "submissions": 0, "run_tasks": 0, "runs": 0}


def test_delegates_run_recovery_to_orchestrator_module_attribute(env, monkeypatch):
    from app.services import orchestrator
    calls: list = []

    def spy(session_factory):
        calls.append(session_factory)
        return 0

    monkeypatch.setattr(orchestrator, "recover_interrupted", spy)
    counts = env.recover()
    assert calls == [env.factory], "recover_interrupted должна быть вызвана ровно один раз с фабрикой сессий"
    assert counts["runs"] == 0 and counts["run_tasks"] == 0
    assert counts["briefs"] == 3 and counts["submissions"] == 4
    assert env.one("run", "R1")["status"] == "queued", "прогоны сам recovery не трогает — это делает оркестратор"


def test_failure_in_run_recovery_propagates_and_leaves_everything_unchanged(env, monkeypatch):
    from app.services import orchestrator

    def boom(session_factory):
        raise RuntimeError("orchestrator recovery failed")

    monkeypatch.setattr(orchestrator, "recover_interrupted", boom)
    before = env.snapshot()
    with pytest.raises(RuntimeError, match="orchestrator recovery failed"):
        env.recover()
    assert env.snapshot() == before, "восстановление должно быть атомарным: частичных изменений быть не может"


# ─────────────────────────────── вызов при старте приложения ───────────────────────────────

def make_app(env: Env):
    from app.config import load_settings
    from app.main import create_app
    return create_app(load_settings({"JUDGE_DATABASE_URL": env.url}))


def test_lifespan_recovers_interrupted_work_on_startup(env):
    from fastapi.testclient import TestClient
    app = make_app(env)
    assert env.one("brief", "B1")["status"] == "processing", "create_app сам ничего не восстанавливает"
    with TestClient(app) as client:
        assert env.one("brief", "B1")["status"] == "failed" and env.one("brief", "B1")["reason"] == REASON
        assert env.one("submission", "S1")["intake_status"] == "failed"
        assert env.one("run", "R1")["status"] == "failed" and env.one("run_task", "T1")["state"] == "failed"
        assert env.one("project", P1)["status"] == "results" and env.one("project", P2)["status"] == "intake"
        assert client.get("/health").status_code == 200


def test_recovery_runs_once_at_startup_not_at_app_creation(env, monkeypatch):
    from fastapi.testclient import TestClient
    from app.services import recovery
    calls: list = []

    def spy(session_factory):
        calls.append(session_factory)
        return {"briefs": 0, "submissions": 0, "run_tasks": 0, "runs": 0}

    monkeypatch.setattr(recovery, "recover_interrupted_work", spy)
    app = make_app(env)
    assert calls == [], "восстановление при создании приложения (не в lifespan) недопустимо"
    with TestClient(app) as client:
        client.get("/health")
        assert calls == [app.state.session_factory]
    assert len(calls) == 1


def test_recovery_failure_does_not_stop_startup_and_is_logged_as_error(env, monkeypatch, caplog):
    from fastapi.testclient import TestClient
    from app.services import recovery

    def boom(session_factory):
        raise RuntimeError("recovery exploded")

    monkeypatch.setattr(recovery, "recover_interrupted_work", boom)
    app = make_app(env)
    with caplog.at_level(logging.ERROR):
        with TestClient(app, raise_server_exceptions=False) as client:
            assert client.get("/health").status_code == 200, "приложение должно стартовать несмотря на ошибку"
    errors = [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert errors, "ошибка восстановления должна попасть в лог уровня ERROR"
