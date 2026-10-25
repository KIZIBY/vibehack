"""T034 + подключение T029 к БД: таблица оценок и пояснение балла (``app.services.results``, ``app.routers.results``).
Тесты написаны ДО реализации (RED).

Контракт (openapi.yaml: Leaderboard / Explanation, data-model.md «Вычисляемое»):
- ``GET /api/v1/projects/{id}/leaderboard?sort=&order=&flag=`` -> ``Leaderboard``; проекта нет -> 404; неизвестные
  ``sort`` (не ``total`` и не id критерия), ``order``, ``flag`` -> 422 ``invalid``; нет подтверждённой рубрики ->
  ``rubric_version: null``, пустые критерии, не 500;
- рубрика таблицы = версия ``project.rubric_confirmed_version``; работы — неудалённые;
- текущая оценка критерия = последняя запись ``criterion_score`` по ``created_at`` (равенство — по ``id``), критерий
  сопоставляется по id или по названию без учёта регистра между версиями рубрики; правка = последняя запись
  ``score_override`` ЭТОЙ записи оценки; ``human``-критерий без оценки -> ``human_pending``;
- флаги: берутся флаги последней завершённой задачи на пару (работа, роль), счётчики по типам;
- ``stale_criteria``: критерии, изменившиеся по смыслу между версией самой старой оценки и подтверждённой;
- ``cost_usd`` = сумма ``run_task.cost_usd`` проекта или ``null``;
- ``GET /api/v1/submissions/{id}/criteria/{criterion_id}`` -> ``Explanation``; ``criterion_id`` — критерий подтверждённой
  версии; ``version`` = число правок записи оценки; битый JSON в ``evidence`` -> ``[]`` и WARNING в лог.

Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import json
import logging
from pathlib import Path

import jsonschema
import pytest
import sqlalchemy as sa
import yaml
from alembic import command
from alembic.config import Config
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / "backend"
OPENAPI = REPO / "specs" / "001-ai-judge-platform" / "contracts" / "openapi.yaml"
TS = "2026-10-25T09:00:00.000000+00:00"
T1 = "2026-10-25T10:00:00.000000+00:00"
T2 = "2026-10-25T11:00:00.000000+00:00"
T3 = "2026-10-25T12:00:00.000000+00:00"
PID = "PROJ0000000000000000000001"
OTHER_PID = "PROJ0000000000000000000002"
DEMO_USER = "demo"
DEMO_PW = "demo-pass-for-tests-0001"
SESSION_SECRET = "test-session-secret-0000000000000001"

# критерии подтверждённой версии 1
C_CODE, C_BIZ, C_HUMAN = "CRIT0000000000000000000001", "CRIT0000000000000000000002", "CRIT0000000000000000000003"
CRITERIA_V1 = [
    (C_CODE, "Код", 2.0, 10.0, "code", "Качество кода"),
    (C_BIZ, "Бизнес", 1.0, 5.0, "business", "Ценность"),
    (C_HUMAN, "Жюри", 1.0, 10.0, "human", "Оценка жюри"),
]
S1, S2, S3 = "SUBM0000000000000000000001", "SUBM0000000000000000000002", "SUBM0000000000000000000003"


# ─────────────────────────────── схемы ───────────────────────────────

def schema_validator(name: str) -> jsonschema.Draft202012Validator:
    doc = yaml.safe_load(OPENAPI.read_text(encoding="utf-8"))
    registry = Registry().with_resource("urn:openapi", Resource.from_contents(doc, default_specification=DRAFT202012))
    return jsonschema.Draft202012Validator({"$ref": f"urn:openapi#/components/schemas/{name}"}, registry=registry)


def assert_valid(name: str, payload: dict) -> None:
    schema_validator(name).validate(payload)


# ─────────────────────────────── окружение ───────────────────────────────

def migrated_url(tmp_path: Path) -> str:
    url = f"sqlite:///{tmp_path / 'db.sqlite'}"
    cfg = Config(str(BACKEND / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND / "migrations"))
    cfg.set_main_option("sqlalchemy.url", url)
    command.upgrade(cfg, "head")
    return url


class Env:
    """Приложение на временной SQLite с миграциями + прямые INSERT для подготовки данных."""

    def __init__(self, tmp_path: Path):
        from app.config import load_settings
        from app.main import create_app

        data_dir = tmp_path / "data"
        data_dir.mkdir()
        env = {
            "JUDGE_DATABASE_URL": migrated_url(tmp_path), "JUDGE_DATA_DIR": str(data_dir),
            "JUDGE_DEMO_USER": DEMO_USER, "JUDGE_DEMO_PASSWORD": DEMO_PW, "JUDGE_SESSION_SECRET": SESSION_SECRET,
        }
        self.app = create_app(load_settings(env))
        self.engine = self.app.state.engine
        self.factory = self.app.state.session_factory
        self._n = 0

    def client(self, *, auth: bool = True, user: str = DEMO_USER):
        from fastapi.testclient import TestClient

        client = TestClient(self.app, raise_server_exceptions=False)
        if auth:
            client.cookies.set("session", self.app.state.sessions.issue(user))
        return client

    def sql(self, statement: str, **params):
        with self.engine.begin() as conn:
            return conn.execute(sa.text(statement), params)

    def rows(self, statement: str, **params) -> list[dict]:
        with self.engine.connect() as conn:
            return [dict(r) for r in conn.execute(sa.text(statement), params).mappings()]

    def nid(self, prefix: str = "GEN") -> str:
        self._n += 1
        return f"{prefix}{self._n:0{26 - len(prefix)}d}"

    # --- данные ---

    def add_project(self, pid: str = PID, confirmed: int | None = None, deleted: bool = False) -> str:
        self.sql(
            "INSERT INTO project (id, name, type, status, agents, required_materials, rubric_confirmed_version, "
            "retention_days, last_activity_at, version, created_at, updated_at, deleted_at) "
            "VALUES (:id, 'Demo', 'other', 'results', '[]', '{}', :cv, 7, :ts, 1, :ts, :ts, :del)",
            id=pid, cv=confirmed, ts=TS, **{"del": TS if deleted else None})
        return pid

    def add_rubric(self, version: int, criteria, pid: str = PID, confirm: bool = True) -> None:
        rid = f"RUBR{pid[-6:]}{version:016d}"
        self.sql("INSERT INTO rubric (id, project_id, version, status, weights_were_missing, confirmed_at, created_at) "
                 "VALUES (:id, :p, :v, :st, 0, :ca, :ts)", id=rid, p=pid, v=version,
                 st="confirmed" if confirm else "draft", ca=TS if confirm else None, ts=TS)
        for position, (cid, name, weight, max_score, agent, description) in enumerate(criteria, start=1):
            self.sql("INSERT INTO criterion (id, rubric_id, position, name, description, weight, max_score, agent) "
                     "VALUES (:id, :r, :pos, :name, :d, :w, :m, :a)", id=cid, r=rid, pos=position, name=name,
                     d=description, w=weight, m=max_score, a=agent)
        if confirm:
            self.sql("UPDATE project SET rubric_confirmed_version = :v WHERE id = :p", v=version, p=pid)

    def add_submission(self, sid: str, team: str, pid: str = PID, deleted: bool = False) -> str:
        self.sql("INSERT INTO submission (id, project_id, team_name, intake_status, version, created_at, deleted_at) "
                 "VALUES (:id, :p, :t, 'ready', 1, :ts, :del)", id=sid, p=pid, t=team, ts=TS,
                 **{"del": TS if deleted else None})
        return sid

    def add_run(self, rid: str, rubric_version: int = 1, pid: str = PID, created_at: str = T1,
                cost: float | None = None) -> str:
        self.sql("INSERT INTO run (id, project_id, rubric_version, status, cost_usd, created_at) "
                 "VALUES (:id, :p, :rv, 'completed', :c, :ts)", id=rid, p=pid, rv=rubric_version, c=cost, ts=created_at)
        return rid

    def add_task(self, tid: str, rid: str, sid: str | None, role: str = "code", state: str = "done",
                 cost: float | None = None) -> str:
        self.sql("INSERT INTO run_task (id, run_id, submission_id, role, state, attempt, cost_usd) "
                 "VALUES (:id, :r, :s, :role, :st, 1, :c)", id=tid, r=rid, s=sid, role=role, st=state, c=cost)
        return tid

    def add_score(self, task: str, sid: str, cid: str, score: float | None = 7.0, *, status: str = "scored",
                  rv: int = 1, max_score: float | None = 10.0, created_at: str = T1, evidence="default",
                  justification: str = "обоснование", confidence: float | None = 0.8, reason: str | None = None,
                  csid: str | None = None) -> str:
        csid = csid or self.nid("CSCR")
        if evidence == "default":
            evidence = json.dumps([{"kind": "file", "ref": "src/app.py:1-9", "quote": "def main"}], ensure_ascii=False)
        elif not isinstance(evidence, str) and evidence is not None:
            evidence = json.dumps(evidence, ensure_ascii=False)
        self.sql(
            "INSERT INTO criterion_score (id, run_task_id, submission_id, criterion_id, rubric_version, status, score, "
            "max_score, justification, evidence, confidence, no_data_reason, version, created_at) "
            "VALUES (:id, :t, :s, :c, :rv, :st, :sc, :m, :j, :e, :conf, :reason, 1, :ts)",
            id=csid, t=task, s=sid, c=cid, rv=rv, st=status, sc=score, m=max_score, j=justification, e=evidence,
            conf=confidence, reason=reason, ts=created_at)
        return csid

    def add_override(self, csid: str, sid: str, cid: str, score: float, reason: str = "жюри не согласно",
                     created_at: str = T2, actor: str = "demo") -> str:
        oid = self.nid("OVRD")
        self.sql("INSERT INTO score_override (id, criterion_score_id, submission_id, criterion_id, score, reason, "
                 "actor, created_at) VALUES (:id, :cs, :s, :c, :sc, :r, :a, :ts)",
                 id=oid, cs=csid, s=sid, c=cid, sc=score, r=reason, a=actor, ts=created_at)
        return oid

    def add_flag(self, task: str, sid: str, type_: str = "plagiarism", *, cid: str | None = None,
                 evidence="default", note: str = "совпадает с репозиторием X", confidence: float = 0.9,
                 created_at: str = T1) -> str:
        fid = self.nid("FLAG")
        if evidence == "default":
            evidence = json.dumps([{"kind": "url", "ref": "https://example.test/x"}])
        elif not isinstance(evidence, str) and evidence is not None:
            evidence = json.dumps(evidence)
        self.sql("INSERT INTO flag (id, run_task_id, submission_id, criterion_id, type, confidence, note, evidence, "
                 "created_at) VALUES (:id, :t, :s, :c, :ty, :conf, :n, :e, :ts)",
                 id=fid, t=task, s=sid, c=cid, ty=type_, conf=confidence, n=note, e=evidence, ts=created_at)
        return fid


@pytest.fixture
def env(tmp_path):
    e = Env(tmp_path)
    e.add_project()
    e.add_rubric(1, CRITERIA_V1)
    e.add_run("RUN00000000000000000000001")
    return e


RUN1 = "RUN00000000000000000000001"
BASE = "/api/v1/projects"


def board(env, **params):
    resp = env.client().get(f"{BASE}/{PID}/leaderboard", params=params)
    assert resp.status_code == 200, resp.text
    payload = resp.json()
    assert_valid("Leaderboard", payload)
    return payload


def row_of(payload, sid):
    return next(r for r in payload["rows"] if r["submission_id"] == sid)


def explain(env, sid, cid, expect=200):
    resp = env.client().get(f"/api/v1/submissions/{sid}/criteria/{cid}")
    assert resp.status_code == expect, resp.text
    if expect == 200:
        assert_valid("Explanation", resp.json())
    return resp.json()


def seed_basic(env):
    """Две работы: S1 — код 8/10 и бизнес 4/5; S2 — только код 6/10."""
    env.add_submission(S1, "Альфа")
    env.add_submission(S2, "Бета")
    t_code1 = env.add_task("TASK0000000000000000000001", RUN1, S1, "code")
    t_biz1 = env.add_task("TASK0000000000000000000002", RUN1, S1, "business")
    t_code2 = env.add_task("TASK0000000000000000000003", RUN1, S2, "code")
    env.add_score(t_code1, S1, C_CODE, 8.0)
    env.add_score(t_biz1, S1, C_BIZ, 4.0, max_score=5.0)
    env.add_score(t_code2, S2, C_CODE, 6.0)
    return t_code1, t_biz1, t_code2


# ─────────────────────────────── таблица ───────────────────────────────

def test_leaderboard_requires_session(env):
    resp = env.client(auth=False).get(f"{BASE}/{PID}/leaderboard")
    assert resp.status_code == 401


def test_leaderboard_unknown_or_deleted_project_is_404(env):
    resp = env.client().get(f"{BASE}/NOPE0000000000000000000000/leaderboard")
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "not_found"
    env.add_project(OTHER_PID, deleted=True)
    assert env.client().get(f"{BASE}/{OTHER_PID}/leaderboard").status_code == 404


def test_leaderboard_without_confirmed_rubric_is_empty_not_500(tmp_path):
    e = Env(tmp_path)
    e.add_project()
    e.add_submission(S1, "Альфа")
    result = board(e)
    assert result["rubric_version"] is None
    assert result["criteria"] == []
    assert result["cost_usd"] is None
    assert [r["submission_id"] for r in result["rows"]] == [S1]
    assert result["rows"][0]["total"] is None and result["rows"][0]["rank"] is None
    assert result["rows"][0]["complete"] is False


def test_leaderboard_basic_totals_ranks_and_cells(env):
    from app.scoring import compute_score

    seed_basic(env)
    result = board(env)
    assert result["rubric_version"] == 1
    assert [c["id"] for c in result["criteria"]] == [C_CODE, C_BIZ, C_HUMAN]
    assert result["criteria"][0] == {"id": C_CODE, "name": "Код", "weight": 2.0, "max_score": 10.0, "agent": "code"}
    r1, r2 = row_of(result, S1), row_of(result, S2)
    expected1 = compute_score([
        {"name": C_CODE, "score": 8.0, "max_score": 10.0, "weight": 2.0},
        {"name": C_BIZ, "score": 4.0, "max_score": 5.0, "weight": 1.0}])["total"]
    expected2 = compute_score([{"name": C_CODE, "score": 6.0, "max_score": 10.0, "weight": 2.0}])["total"]
    assert r1["total"] == expected1 and r2["total"] == expected2
    assert (r1["rank"], r2["rank"]) == (1, 2)
    assert r1["team_name"] == "Альфа"
    assert r1["cells"][C_CODE] == {"status": "scored", "score": 8.0, "max_score": 10.0, "overridden": False, "stale": False}
    assert r1["cells"][C_HUMAN]["status"] == "human_pending"
    assert r2["cells"][C_BIZ]["status"] == "not_evaluated"
    assert r1["complete"] is False and r2["complete"] is False
    assert [r["submission_id"] for r in result["rows"]] == [S1, S2]


def test_leaderboard_excludes_deleted_submissions(env):
    seed_basic(env)
    env.add_submission(S3, "Удалённые", deleted=True)
    task = env.add_task("TASK0000000000000000000009", RUN1, S3, "code")
    env.add_score(task, S3, C_CODE, 10.0)
    ids = [r["submission_id"] for r in board(env)["rows"]]
    assert S3 not in ids and set(ids) == {S1, S2}


def test_leaderboard_ignores_other_projects(env):
    seed_basic(env)
    env.add_project(OTHER_PID)
    env.add_submission(S3, "Чужая", pid=OTHER_PID)
    assert S3 not in [r["submission_id"] for r in board(env)["rows"]]


def test_latest_score_record_wins_and_tie_breaks_by_id(env):
    env.add_submission(S1, "Альфа")
    t_old = env.add_task("TASK0000000000000000000001", RUN1, S1, "code")
    env.add_run("RUN00000000000000000000002", created_at=T2)
    t_new = env.add_task("TASK0000000000000000000002", "RUN00000000000000000000002", S1, "code")
    env.add_score(t_old, S1, C_CODE, 3.0, created_at=T1)
    env.add_score(t_new, S1, C_CODE, 9.0, created_at=T2)
    assert row_of(board(env), S1)["cells"][C_CODE]["score"] == 9.0
    # равный created_at — побеждает больший id
    env.add_score(t_new, S1, C_CODE, 5.0, created_at=T2, csid="CSCR9999999999999999999999")
    assert row_of(board(env), S1)["cells"][C_CODE]["score"] == 5.0


def test_newer_no_data_record_supersedes_older_score(env):
    env.add_submission(S1, "Альфа")
    t_old = env.add_task("TASK0000000000000000000001", RUN1, S1, "code")
    env.add_run("RUN00000000000000000000002", created_at=T2)
    t_new = env.add_task("TASK0000000000000000000002", "RUN00000000000000000000002", S1, "code", state="no_data")
    env.add_score(t_old, S1, C_CODE, 8.0, created_at=T1)
    env.add_score(t_new, S1, C_CODE, None, status="no_data", reason="нет материалов", created_at=T2)
    cell = row_of(board(env), S1)["cells"][C_CODE]
    assert cell["status"] == "no_data" and cell["score"] is None


def test_override_replaces_score_and_last_override_wins(env):
    env.add_submission(S1, "Альфа")
    task = env.add_task("TASK0000000000000000000001", RUN1, S1, "code")
    csid = env.add_score(task, S1, C_CODE, 4.0)
    env.add_override(csid, S1, C_CODE, 6.0, created_at=T1)
    env.add_override(csid, S1, C_CODE, 9.0, created_at=T2)
    cell = row_of(board(env), S1)["cells"][C_CODE]
    assert (cell["score"], cell["overridden"], cell["status"]) == (9.0, True, "scored")
    # исходная запись агента не меняется
    assert env.rows("SELECT score FROM criterion_score WHERE id = :i", i=csid)[0]["score"] == 4.0


def test_override_of_superseded_record_is_ignored(env):
    env.add_submission(S1, "Альфа")
    t_old = env.add_task("TASK0000000000000000000001", RUN1, S1, "code")
    old = env.add_score(t_old, S1, C_CODE, 4.0, created_at=T1)
    env.add_override(old, S1, C_CODE, 10.0, created_at=T1)
    env.add_run("RUN00000000000000000000002", created_at=T2)
    t_new = env.add_task("TASK0000000000000000000002", "RUN00000000000000000000002", S1, "code")
    env.add_score(t_new, S1, C_CODE, 7.0, created_at=T2)
    cell = row_of(board(env), S1)["cells"][C_CODE]
    assert (cell["score"], cell["overridden"]) == (7.0, False)


def test_scores_of_previous_rubric_version_matched_by_name_and_stale(env):
    """Рубрика v2 с новыми id: оценка v1 сопоставляется по названию без учёта регистра; изменилось описание -> stale."""
    new_code, new_biz = "CRIT00000000000000000000V2", "CRIT00000000000000000000V3"
    env.add_rubric(2, [
        (new_code, "КОД", 2.0, 10.0, "code", "Качество кода"),          # смысл тот же
        (new_biz, "Бизнес", 1.0, 5.0, "business", "Новое описание"),  # смысл изменился
    ])
    env.add_submission(S1, "Альфа")
    t1 = env.add_task("TASK0000000000000000000001", RUN1, S1, "code")
    t2 = env.add_task("TASK0000000000000000000002", RUN1, S1, "business")
    env.add_score(t1, S1, C_CODE, 8.0, rv=1)
    env.add_score(t2, S1, C_BIZ, 4.0, rv=1, max_score=5.0)
    result = board(env)
    assert result["rubric_version"] == 2
    assert result["stale_criteria"] == [new_biz]
    cells = row_of(result, S1)["cells"]
    assert cells[new_code]["score"] == 8.0 and cells[new_code]["stale"] is False
    assert cells[new_biz]["score"] == 4.0 and cells[new_biz]["stale"] is True


def test_no_stale_when_scores_are_current_version(env):
    seed_basic(env)
    assert board(env)["stale_criteria"] == []


def test_out_of_range_score_in_db_does_not_break_table(env):
    env.add_submission(S1, "Альфа")
    task = env.add_task("TASK0000000000000000000001", RUN1, S1, "code")
    env.add_score(task, S1, C_CODE, 99.0)
    result = board(env)
    cell = row_of(result, S1)["cells"][C_CODE]
    assert cell["status"] == "no_data" and cell["score"] is None
    assert row_of(result, S1)["total"] is None


def test_flag_counts_filter_and_validation(env):
    seed_basic(env)
    t = env.add_task("TASK0000000000000000000010", RUN1, S1, "critic-uniqueness")
    env.add_flag(t, S1, "plagiarism")
    env.add_flag(t, S1, "plagiarism")
    env.add_flag(t, S1, "secret_exposed")
    result = board(env)
    assert row_of(result, S1)["flags"] == [{"type": "plagiarism", "count": 2}, {"type": "secret_exposed", "count": 1}]
    assert row_of(result, S2)["flags"] == []
    only = board(env, flag="plagiarism")
    assert [r["submission_id"] for r in only["rows"]] == [S1]
    assert row_of(only, S1)["rank"] == 1   # ранг считается по всей таблице
    assert board(env, flag="secret_exposed")["rows"][0]["submission_id"] == S1
    assert board(env, flag="prompt_injection")["rows"] == []


def test_flags_come_from_latest_finished_task_per_role(env):
    env.add_submission(S1, "Альфа")
    old = env.add_task("TASK0000000000000000000001", RUN1, S1, "critic-uniqueness")
    env.add_flag(old, S1, "plagiarism")
    env.add_flag(old, S1, "secret_exposed")
    env.add_run("RUN00000000000000000000002", created_at=T2)
    new = env.add_task("TASK0000000000000000000002", "RUN00000000000000000000002", S1, "critic-uniqueness")
    env.add_flag(new, S1, "plagiarism", created_at=T2)
    other_role = env.add_task("TASK0000000000000000000003", RUN1, S1, "critic-honesty")
    env.add_flag(other_role, S1, "claim_mismatch")
    flags = row_of(board(env), S1)["flags"]
    assert flags == [{"type": "claim_mismatch", "count": 1}, {"type": "plagiarism", "count": 1}]


@pytest.mark.parametrize("params", [
    {"sort": "no-such-column"}, {"order": "sideways"}, {"flag": "not_a_flag"}, {"flag": ""}, {"sort": ""},
])
def test_leaderboard_invalid_params_are_422(env, params):
    seed_basic(env)
    resp = env.client().get(f"{BASE}/{PID}/leaderboard", params=params)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "invalid"


def test_leaderboard_sort_by_criterion_and_order(env):
    seed_basic(env)
    desc = board(env, sort=C_CODE, order="desc")
    assert [r["submission_id"] for r in desc["rows"]] == [S1, S2]
    asc = board(env, sort=C_CODE, order="asc")
    assert [r["submission_id"] for r in asc["rows"]] == [S2, S1]
    assert board(env, sort="total", order="asc")["rows"][0]["submission_id"] == S2


def test_leaderboard_cost_is_sum_of_run_tasks_or_null(env):
    seed_basic(env)
    assert board(env)["cost_usd"] is None   # стоимость задач неизвестна
    env.sql("UPDATE run_task SET cost_usd = 0.25 WHERE id = 'TASK0000000000000000000001'")
    env.sql("UPDATE run_task SET cost_usd = 0.5 WHERE id = 'TASK0000000000000000000002'")
    env.add_task("TASK0000000000000000000020", RUN1, None, "rubric", cost=0.125)   # задача уровня проекта
    assert board(env)["cost_usd"] == pytest.approx(0.875)


def test_leaderboard_bad_evidence_json_in_flag_does_not_break(env):
    seed_basic(env)
    t = env.add_task("TASK0000000000000000000010", RUN1, S1, "critic-uniqueness")
    env.add_flag(t, S1, "plagiarism", evidence="{not json")
    result = board(env)
    assert row_of(result, S1)["flags"] == [{"type": "plagiarism", "count": 1}]


# ─────────────────────────────── пояснение ───────────────────────────────

def test_explanation_requires_session(env):
    seed_basic(env)
    assert env.client(auth=False).get(f"/api/v1/submissions/{S1}/criteria/{C_CODE}").status_code == 401


def test_explanation_scored_fields(env):
    seed_basic(env)
    payload = explain(env, S1, C_CODE)
    assert payload["criterion_id"] == C_CODE and payload["criterion_name"] == "Код"
    assert payload["team_name"] == "Альфа" and payload["status"] == "scored"
    assert payload["score"] == 8.0 and payload["agent_score"] == 8.0 and payload["max_score"] == 10.0
    assert payload["agent"] == "code" and payload["justification"] == "обоснование"
    assert payload["confidence"] == 0.8 and payload["override"] is None and payload["version"] == 0
    assert payload["evidence"] == [{"kind": "file", "ref": "src/app.py:1-9", "quote": "def main", "available": True}]
    assert payload["flags"] == [] and payload["run_id"] == RUN1


def test_explanation_with_override_keeps_agent_score_and_counts_version(env):
    env.add_submission(S1, "Альфа")
    task = env.add_task("TASK0000000000000000000001", RUN1, S1, "code")
    csid = env.add_score(task, S1, C_CODE, 4.0)
    env.add_override(csid, S1, C_CODE, 6.0, reason="первая", created_at=T1)
    env.add_override(csid, S1, C_CODE, 9.0, reason="вторая", created_at=T2)
    payload = explain(env, S1, C_CODE)
    assert payload["score"] == 9.0 and payload["agent_score"] == 4.0
    assert payload["version"] == 2
    assert payload["override"]["score"] == 9.0 and payload["override"]["reason"] == "вторая"
    assert payload["override"]["at"].startswith("2026-10-25T11:00:00")


def test_explanation_human_pending_and_not_evaluated(env):
    seed_basic(env)
    human = explain(env, S1, C_HUMAN)
    assert human["status"] == "human_pending" and human["score"] is None and human["version"] == 0
    assert human["evidence"] == []
    missing = explain(env, S2, C_BIZ)
    assert missing["status"] == "no_data" and missing["version"] == 0


def test_explanation_includes_only_flags_of_this_criterion(env):
    seed_basic(env)
    t = env.add_task("TASK0000000000000000000010", RUN1, S1, "critic-honesty")
    env.add_flag(t, S1, "claim_mismatch", cid=C_CODE, note="не подтверждено",
                 evidence=[{"kind": "claim", "ref": "claim-1", "quote": "x"}])
    env.add_flag(t, S1, "plagiarism", cid=C_BIZ)
    env.add_flag(t, S1, "agent_failure", cid=None)
    flags = explain(env, S1, C_CODE)["flags"]
    assert len(flags) == 1
    assert flags[0]["type"] == "claim_mismatch" and flags[0]["criterion_id"] == C_CODE
    assert flags[0]["note"] == "не подтверждено"
    assert flags[0]["evidence"] == [{"kind": "claim", "ref": "claim-1", "quote": "x", "available": True}]


def test_explanation_404_cases(env):
    seed_basic(env)
    explain(env, "NOPE0000000000000000000000", C_CODE, expect=404)
    explain(env, S1, "NOPE0000000000000000000000", expect=404)
    env.add_submission(S3, "Удалённые", deleted=True)
    explain(env, S3, C_CODE, expect=404)
    # критерий прошлой версии рубрики — не критерий подтверждённой версии
    env.add_rubric(2, [("CRIT00000000000000000000V2", "Код", 2.0, 10.0, "code", "Качество кода")])
    explain(env, S1, C_CODE, expect=404)
    explain(env, S1, "CRIT00000000000000000000V2")
    # критерий чужого проекта
    env.add_project(OTHER_PID)
    env.add_rubric(1, [("CRIT0000000000000000OTHER1", "Код", 1.0, 10.0, "code", "")], pid=OTHER_PID)
    explain(env, S1, "CRIT0000000000000000OTHER1", expect=404)


def test_explanation_for_project_without_confirmed_rubric_is_404(tmp_path):
    e = Env(tmp_path)
    e.add_project()
    e.add_rubric(1, CRITERIA_V1, confirm=False)
    e.add_submission(S1, "Альфа")
    explain(e, S1, C_CODE, expect=404)


def test_explanation_bad_evidence_json_gives_empty_list_and_warning(env, caplog):
    from app.services import results

    env.add_submission(S1, "Альфа")
    task = env.add_task("TASK0000000000000000000001", RUN1, S1, "code")
    env.add_score(task, S1, C_CODE, 8.0, evidence="{это не json")
    with caplog.at_level(logging.WARNING):
        with env.factory() as session:
            payload = results.explanation(session, S1, C_CODE)
    assert payload["evidence"] == []
    assert payload["status"] == "scored" and payload["score"] == 8.0
    assert any(r.levelno >= logging.WARNING for r in caplog.records)
    # и через HTTP — не 500
    assert explain(env, S1, C_CODE)["evidence"] == []


def test_explanation_non_list_evidence_json_gives_empty_list(env):
    env.add_submission(S1, "Альфа")
    task = env.add_task("TASK0000000000000000000001", RUN1, S1, "code")
    env.add_score(task, S1, C_CODE, 8.0, evidence=json.dumps({"kind": "file"}))
    assert explain(env, S1, C_CODE)["evidence"] == []


def test_explanation_out_of_range_score_is_no_data(env):
    env.add_submission(S1, "Альфа")
    task = env.add_task("TASK0000000000000000000001", RUN1, S1, "code")
    env.add_score(task, S1, C_CODE, -3.0)
    payload = explain(env, S1, C_CODE)
    assert payload["status"] == "no_data" and payload["score"] is None
