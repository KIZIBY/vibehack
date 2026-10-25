"""T032: API прогонов (``app.routers.runs``). Тесты написаны ДО реализации (RED).

Контракт (openapi.yaml: ``/api/v1/projects/{id}/runs`` GET/POST, ``/api/v1/runs/{run_id}``, схема Run):
- ``POST …/runs`` (тело необязательно: ``submission_ids``, ``roles``, ``criterion_ids``) -> 202 ``Run``; проверки по
  порядку: проекта нет -> 404; шлюз не настроен -> 503; рубрика не подтверждена -> 409 ``rubric_not_confirmed``;
  в проекте уже идёт прогон (``queued|running``) -> 409 ``conflict``; нет подходящих работ -> 409; чужие,
  несуществующие или удалённые id работ, неизвестные критерии, неизвестная роль -> 422;
- выполнение идёт в фоне (``asyncio.create_task``, ссылки в ``app.state.run_jobs``), ответ не ждёт; паузу между
  повторами можно подменить через ``app.state.run_sleep``;
- ``GET …/runs`` — новые сверху; ``GET /api/v1/runs/{run_id}`` — ``Run`` с ``tasks[]``; нет -> 404;
- все эндпоинты за сессией.

Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import asyncio
import json
import time
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
TS = "2026-01-01 00:00:00.000000"
PID = "PROJ0000000000000000000001"
OTHER_PID = "PROJ0000000000000000000002"
S1, S2, S_PENDING = "SUBM0000000000000000000001", "SUBM0000000000000000000002", "SUBM0000000000000000000003"
FOREIGN_SUB = "SUBM0000000000000000000009"
ROLES5 = ["code", "business", "design", "critic-uniqueness", "critic-honesty"]
CRITERIA = {"C_CODE": ("code", 10), "C_BIZ": ("business", 10), "C_DES": ("design", 10),
            "C_UNI": ("critic-uniqueness", 10), "C_HON": ("critic-honesty", 10)}
ROLE_CRITERION = {role: cid for cid, (role, _) in CRITERIA.items()}
DEMO_USER = "demo"
DEMO_PW = "demo-pass-for-tests-0001"
SESSION_SECRET = "test-session-secret-0000000000000001"


def schema_of(name: str) -> dict:
    doc = yaml.safe_load(OPENAPI.read_text(encoding="utf-8"))
    return {"$ref": f"#/components/schemas/{name}", "components": doc["components"]}


def assert_run(payload) -> None:
    jsonschema.validate(payload, schema_of("Run"), format_checker=jsonschema.FormatChecker())


def migrated_url(tmp_path: Path) -> str:
    url = f"sqlite:///{tmp_path / 'db.sqlite'}"
    cfg = Config(str(BACKEND / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND / "migrations"))
    cfg.set_main_option("sqlalchemy.url", url)
    command.upgrade(cfg, "head")
    return url


def scores_template(role: str) -> dict:
    return {
        "schema_version": "1", "kind": "scores", "run_id": "X", "submission_id": "X", "role": role, "rubric_version": 1,
        "scores": [{"criterion_id": ROLE_CRITERION[role], "status": "scored", "score": 8, "max_score": 10,
                    "justification": "Есть тесты и разделение слоёв.",
                    "evidence": [{"kind": "file", "ref": "api/routes.py:40-88"}], "confidence": 0.8}],
        "flags": [],
    }


def make_gateway(data_dir: Path, **kw):
    """FakeAgentGateway + документ метрик UX для project-level задачи роли design (submission_id=None)."""
    from app.services.gateway import FakeAgentGateway, RoleResult

    class UxGateway(FakeAgentGateway):
        async def run_role(self, run):
            if run.role == "design" and run.submission_id is None:
                target = data_dir / "runs" / run.run_id / "reports"
                target.mkdir(parents=True, exist_ok=True)
                project_id = run.workdir.split("/")[1]
                (target / "design__project.json").write_text(json.dumps({
                    "schema_version": "1", "kind": "ux_metrics", "project_id": project_id,
                    "metrics": [{"name": "Время до действия", "how_to_measure": "секундомер",
                                 "good_looks_like": "< 5 с"}]}), encoding="utf-8")
                return RoleResult(status="completed", hermes_run_id="h-ux")
            return await super().run_role(run)

    return UxGateway(data_dir, {role: scores_template(role) for role in ROLES5}, **kw)


class Env:
    def __init__(self, tmp_path: Path, *, gateway: bool = True, confirmed: bool = True):
        from app.config import load_settings
        from app.main import create_app

        self.tmp = tmp_path
        self.data_dir = tmp_path / "data"
        self.data_dir.mkdir()
        env = {"JUDGE_DATABASE_URL": migrated_url(tmp_path), "JUDGE_DATA_DIR": str(self.data_dir),
               "JUDGE_DEMO_USER": DEMO_USER, "JUDGE_DEMO_PASSWORD": DEMO_PW, "JUDGE_SESSION_SECRET": SESSION_SECRET}
        self.app = create_app(load_settings(env))
        self.engine = self.app.state.engine
        self.gateway = None
        if gateway:
            self.gateway = make_gateway(self.data_dir)
            self.app.state.gateway = self.gateway

        async def no_sleep(seconds):
            await asyncio.sleep(0)

        self.app.state.run_sleep = no_sleep
        self.seed(confirmed)

    def client(self, *, auth: bool = True):
        from fastapi.testclient import TestClient

        client = TestClient(self.app, raise_server_exceptions=False)
        if auth:
            client.cookies.set("session", self.app.state.sessions.issue(DEMO_USER))
        return client

    def sql(self, statement: str, **params) -> None:
        with self.engine.begin() as conn:
            conn.execute(sa.text(statement), params)

    def rows(self, statement: str, **params) -> list[dict]:
        with self.engine.connect() as conn:
            return [dict(r) for r in conn.execute(sa.text(statement), params).mappings()]

    def seed(self, confirmed: bool) -> None:
        for pid in (PID, OTHER_PID):
            self.sql(
                "INSERT INTO project (id, name, type, status, agents, required_materials, rubric_confirmed_version, "
                "retention_days, last_activity_at, version, created_at, updated_at) "
                "VALUES (:id, 'Demo', 'other', 'intake', :agents, '[]', :rcv, 7, :ts, 1, :ts, :ts)",
                id=pid, agents=json.dumps(ROLES5 + ["human"]), rcv=1 if confirmed else None, ts=TS)
        for sid, pid, intake in ((S1, PID, "ready"), (S2, PID, "ready"), (S_PENDING, PID, "pending"),
                                 (FOREIGN_SUB, OTHER_PID, "ready")):
            self.sql("INSERT INTO submission (id, project_id, team_name, intake_status, version, created_at) "
                     "VALUES (:id, :p, :id, :intake, 1, :ts)", id=sid, p=pid, intake=intake, ts=TS)
        self.sql("INSERT INTO rubric (id, project_id, version, status, weights_were_missing, confirmed_at, created_at) "
                 "VALUES ('RUBRIC_1', :p, 1, :status, 0, :ts, :ts)",
                 p=PID, status="confirmed" if confirmed else "draft", ts=TS)
        for position, (cid, (agent, max_score)) in enumerate(CRITERIA.items()):
            self.sql("INSERT INTO criterion (id, rubric_id, position, name, description, weight, max_score, agent) "
                     "VALUES (:id, 'RUBRIC_1', :pos, :id, '', 1, :max, :agent)",
                     id=cid, pos=position, max=max_score, agent=agent)


@pytest.fixture
def env(tmp_path):
    return Env(tmp_path)


def wait_finished(client, run_id: str, timeout: float = 10.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        body = client.get(f"/api/v1/runs/{run_id}").json()
        if body["status"] in ("completed", "partial", "failed"):
            return body
        time.sleep(0.02)
    raise AssertionError("прогон не завершился")


RUNS = f"/api/v1/projects/{PID}/runs"


# ─────────────────────────────── доступ и проверки ───────────────────────────────

def test_endpoints_require_a_session(env):
    anonymous = env.client(auth=False)
    assert anonymous.get(RUNS).status_code == 401
    assert anonymous.post(RUNS, json={}).status_code == 401
    assert anonymous.get("/api/v1/runs/anything").status_code == 401


def test_unknown_project_is_404(env):
    client = env.client()
    assert client.post("/api/v1/projects/NOPE/runs", json={}).status_code == 404
    assert client.get("/api/v1/projects/NOPE/runs").status_code == 404


def test_gateway_not_configured_is_503_and_nothing_is_created(tmp_path):
    env = Env(tmp_path, gateway=False)
    response = env.client().post(RUNS, json={})
    assert response.status_code == 503
    assert env.rows("SELECT * FROM run") == []


def test_unconfirmed_rubric_is_409_rubric_not_confirmed(tmp_path):
    env = Env(tmp_path, confirmed=False)
    response = env.client().post(RUNS, json={})
    assert response.status_code == 409 and response.json()["error"]["code"] == "rubric_not_confirmed"
    assert env.rows("SELECT * FROM run") == []


def test_active_run_is_409_conflict(env):
    env.sql("INSERT INTO run (id, project_id, rubric_version, status, created_at) "
            "VALUES ('RUNACTIVE', :p, 1, 'running', :ts)", p=PID, ts=TS)
    response = env.client().post(RUNS, json={})
    assert response.status_code == 409 and response.json()["error"]["code"] == "conflict"
    assert len(env.rows("SELECT * FROM run")) == 1
    env.sql("UPDATE run SET status = 'queued'")
    assert env.client().post(RUNS, json={}).status_code == 409
    env.sql("UPDATE run SET status = 'partial', finished_at = :ts", ts=TS)
    with env.client() as client:
        assert client.post(RUNS, json={}).status_code == 202


def test_no_ready_submissions_is_409(env):
    env.sql("UPDATE submission SET intake_status = 'pending'")
    response = env.client().post(RUNS, json={})
    assert response.status_code == 409 and response.json()["error"]["message"]
    assert env.rows("SELECT * FROM run") == []


@pytest.mark.parametrize("body", [
    {"submission_ids": [FOREIGN_SUB]},
    {"submission_ids": ["NOPE"]},
    {"criterion_ids": ["NOPE"]},
    {"roles": ["wizard"]},
    {"roles": ["human"]},
    {"submission_ids": "SUBM0000000000000000000001"},
])
def test_invalid_request_is_422(env, body):
    response = env.client().post(RUNS, json=body)
    assert response.status_code == 422 and response.json()["error"]["code"] == "invalid"
    assert env.rows("SELECT * FROM run") == []


def test_pending_submission_requested_explicitly_is_409(env):
    assert env.client().post(RUNS, json={"submission_ids": [S_PENDING]}).status_code == 409


# ─────────────────────────────── запуск и чтение ───────────────────────────────

def test_start_run_returns_202_run_and_finishes_in_background(env):
    with env.client() as client:
        response = client.post(RUNS)                            # тело необязательно
        assert response.status_code == 202
        body = response.json()
        assert_run(body)
        assert body["project_id"] == PID and body["status"] in ("queued", "running")
        assert len(body["tasks"]) == 11                         # 2 работы × 5 ролей + метрики UX
        assert {t["submission_id"] for t in body["tasks"]} == {S1, S2, None}
        assert hasattr(env.app.state, "run_jobs")

        finished = wait_finished(client, body["id"])
        assert_run(finished)
        assert finished["status"] == "completed" and finished["finished_at"] is not None
        assert finished["tokens_in"] is None and finished["tokens_out"] is None and finished["cost_usd"] is None
        assert all(t["state"] == "done" and t["attempt"] == 1 for t in finished["tasks"])
        assert all("reason" not in t for t in finished["tasks"])      # reason — строка: без значения поля нет
    assert env.rows("SELECT status FROM project WHERE id = :p", p=PID)[0]["status"] == "results"
    assert (env.data_dir / "projects" / PID / "rubric.json").is_file()


def test_empty_object_body_is_accepted(env):
    with env.client() as client:
        assert client.post(RUNS, json={}).status_code == 202


def test_failed_role_is_reported_in_tasks(tmp_path):
    env = Env(tmp_path)
    env.app.state.gateway = make_gateway(env.data_dir, fail_roles=["code"])
    with env.client() as client:
        run_id = client.post(RUNS, json={"submission_ids": [S1], "roles": ["code", "business"]}).json()["id"]
        finished = wait_finished(client, run_id)
    assert_run(finished)
    assert finished["status"] == "partial"
    by_role = {t["role"]: t for t in finished["tasks"]}
    assert by_role["code"]["state"] == "no_data" and by_role["code"]["attempt"] == 3
    assert by_role["code"]["reason"] == "simulated_failure"
    assert by_role["business"]["state"] == "done"


def test_restart_selected_submission_role_and_criterion(env):
    with env.client() as client:
        first = client.post(RUNS, json={}).json()
        wait_finished(client, first["id"])
        second = client.post(RUNS, json={"submission_ids": [S2], "criterion_ids": ["C_BIZ"]})
        assert second.status_code == 202
        body = second.json()
        assert [(t["submission_id"], t["role"]) for t in body["tasks"]] == [(S2, "business")]
        wait_finished(client, body["id"])
    rows = env.rows("SELECT id FROM criterion_score WHERE submission_id = :s AND criterion_id = 'C_BIZ'", s=S2)
    assert len(rows) == 2                                       # старая оценка осталась (FR-024)


def test_list_runs_newest_first(env):
    with env.client() as client:
        first = client.post(RUNS, json={"roles": ["code"]}).json()
        wait_finished(client, first["id"])
        second = client.post(RUNS, json={"roles": ["business"]}).json()
        wait_finished(client, second["id"])
        listing = client.get(RUNS)
    assert listing.status_code == 200
    items = listing.json()["items"]
    assert [item["id"] for item in items] == [second["id"], first["id"]]
    jsonschema.validate(listing.json(), {
        "type": "object", "required": ["items"], "components": schema_of("Run")["components"],
        "properties": {"items": {"type": "array", "items": {"$ref": "#/components/schemas/Run"}}}},
        format_checker=jsonschema.FormatChecker())


def test_runs_of_other_project_are_not_listed_and_get_unknown_run_is_404(env):
    client = env.client()
    assert client.get(f"/api/v1/projects/{OTHER_PID}/runs").json() == {"items": []}
    assert client.get("/api/v1/runs/UNKNOWN").status_code == 404
