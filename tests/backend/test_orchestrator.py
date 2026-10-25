"""T032: оркестратор оценки (``app.services.orchestrator``). Тесты написаны ДО реализации (RED).

Контракт (задача T032, contracts/agent-run.md §1–§3, openapi.yaml: Run):
- ``create_run(session, *, storage, project_id, submission_ids=None, roles=None, criterion_ids=None) -> dict`` создаёт
  ``run`` (``queued``, ``rubric_version`` подтверждённой рубрики, ``requested``) и ``run_task`` на каждую пару
  «работа × роль» (``queued``, ``attempt=0``) плюс одну project-level задачу ``design`` (``submission_id=NULL``), если
  роль включена, а метрик UX проекта ещё нет; пишет ``projects/<project_id>/rubric.json`` и переводит проект в
  ``evaluating``; возвращает схему ``Run``. Коммит делает вызывающий код;
- ``Orchestrator(session_factory, gateway, data_dir, bus, *, max_parallel=5, sleep=asyncio.sleep).execute(run_id)``:
  граф на работу ``code ‖ business ‖ design ‖ critic-uniqueness`` -> ``critic-honesty``; ``design`` работ ждёт
  project-level задачу метрик; до 3 попыток, паузы 2 и 4 с; после исчерпания попыток задача ``no_data`` (причина
  роли), а ``ingest_report`` всё равно пишет ``no_data`` + флаг ``agent_failure`` по критериям роли; сбой одной роли
  не валит остальные; статус прогона ``completed|partial|failed``; проект ``evaluating -> results``;
- события ``run.progress``/``score.changed``/``run.completed``/``message.created`` и системное сообщение чата;
- ``recover_interrupted(session_factory) -> int``: ``running|queued`` задачи и прогоны -> ``failed`` (``interrupted``).

Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import asyncio
import json
import logging
from collections import defaultdict
from pathlib import Path

import pytest
import sqlalchemy as sa
from alembic import command
from alembic.config import Config

REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / "backend"
TS = "2026-01-01 00:00:00.000000"
PID = "PROJ0000000000000000000001"
OTHER_PID = "PROJ0000000000000000000002"
S1, S2, S3_PENDING, S4_DELETED = ("SUBM000000000000000000000%d" % i for i in (1, 2, 3, 4))
FOREIGN_SUB = "SUBM0000000000000000000009"
ROLES5 = ["code", "business", "design", "critic-uniqueness", "critic-honesty"]
# критерий -> (роль, max_score)
CRITERIA = {"C_CODE": ("code", 10), "C_BIZ": ("business", 10), "C_DES": ("design", 10),
            "C_UNI": ("critic-uniqueness", 10), "C_HON": ("critic-honesty", 10), "C_HUM": ("human", 10)}
ROLE_CRITERION = {role: cid for cid, (role, _) in CRITERIA.items()}


def migrated_url(tmp_path: Path) -> str:
    url = f"sqlite:///{tmp_path / 'db.sqlite'}"
    cfg = Config(str(BACKEND / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND / "migrations"))
    cfg.set_main_option("sqlalchemy.url", url)
    command.upgrade(cfg, "head")
    return url


class Env:
    def __init__(self, tmp_path: Path):
        from app.db import make_engine, make_session_factory
        from app.services.events import EventBus
        from app.services.storage import Storage

        self.tmp = tmp_path
        self.data_dir = tmp_path / "data"
        self.data_dir.mkdir()
        self.engine = make_engine(migrated_url(tmp_path))
        self.factory = make_session_factory(self.engine)
        self.storage = Storage(self.data_dir)
        self.bus = EventBus()
        self.seed()

    def sql(self, statement: str, **params) -> None:
        with self.engine.begin() as conn:
            conn.execute(sa.text(statement), params)

    def rows(self, statement: str, **params) -> list[dict]:
        with self.engine.connect() as conn:
            return [dict(r) for r in conn.execute(sa.text(statement), params).mappings()]

    def seed(self, *, status: str = "intake", agents=None, confirmed: bool = True) -> None:
        agents = ROLES5 + ["human"] if agents is None else agents
        for pid in (PID, OTHER_PID):
            self.sql(
                "INSERT INTO project (id, name, type, status, agents, required_materials, rubric_confirmed_version, "
                "retention_days, last_activity_at, version, created_at, updated_at) "
                "VALUES (:id, 'Demo', 'other', :status, :agents, '[]', :rcv, 7, :ts, 1, :ts, :ts)",
                id=pid, status=status, agents=json.dumps(agents), rcv=1 if confirmed else None, ts=TS)
        for sid, pid, intake, deleted in ((S1, PID, "ready", None), (S2, PID, "ready", None),
                                          (S3_PENDING, PID, "pending", None), (S4_DELETED, PID, "ready", TS),
                                          (FOREIGN_SUB, OTHER_PID, "ready", None)):
            self.sql("INSERT INTO submission (id, project_id, team_name, intake_status, version, created_at, "
                     "deleted_at) VALUES (:id, :p, :id, :intake, 1, :ts, :deleted)",
                     id=sid, p=pid, intake=intake, ts=TS, deleted=deleted)
        self.sql("INSERT INTO rubric (id, project_id, version, status, weights_were_missing, confirmed_at, "
                 "created_at) VALUES ('RUBRIC_1', :p, 1, :status, 0, :ts, :ts)",
                 p=PID, status="confirmed" if confirmed else "draft", ts=TS)
        for position, (cid, (agent, max_score)) in enumerate(CRITERIA.items()):
            self.sql("INSERT INTO criterion (id, rubric_id, position, name, description, weight, max_score, agent, "
                     "anchors) VALUES (:id, 'RUBRIC_1', :pos, :name, '', 2, :max, :agent, :anchors)",
                     id=cid, pos=position, name=f"Критерий {cid}", max=max_score, agent=agent,
                     anchors=json.dumps([{"score": 0, "meaning": "нет"}, {"score": 10, "meaning": "отлично"}]))

    def create(self, **kw) -> dict:
        from app.db import session_scope
        from app.services import orchestrator

        with session_scope(self.factory) as session:
            return orchestrator.create_run(session, storage=self.storage, project_id=PID, **kw)

    def orchestrator(self, gateway, *, sleep=None, max_parallel: int = 5, **extra):
        from app.services.orchestrator import Orchestrator

        return Orchestrator(self.factory, gateway, self.data_dir, self.bus, max_parallel=max_parallel,
                            sleep=sleep or instant_sleep(None), **extra)

    def execute(self, run_id: str, gateway, *, sleep=None, max_parallel: int = 5, **extra) -> None:
        asyncio.run(self.orchestrator(gateway, sleep=sleep, max_parallel=max_parallel, **extra).execute(run_id))

    def run(self, run_id: str) -> dict:
        return self.rows("SELECT * FROM run WHERE id = :r", r=run_id)[0]

    def tasks(self, run_id: str, role: str | None = None, sub: str | None = "any") -> list[dict]:
        rows = self.rows("SELECT * FROM run_task WHERE run_id = :r ORDER BY id", r=run_id)
        return [t for t in rows if (role is None or t["role"] == role) and (sub == "any" or t["submission_id"] == sub)]

    def scores(self, sub: str) -> dict[str, list[dict]]:
        out: dict[str, list[dict]] = defaultdict(list)
        for row in self.rows("SELECT * FROM criterion_score WHERE submission_id = :s ORDER BY created_at, id", s=sub):
            out[row["criterion_id"]].append(row)
        return out

    def project_status(self) -> str:
        return self.rows("SELECT status FROM project WHERE id = :p", p=PID)[0]["status"]


@pytest.fixture
def env(tmp_path):
    return Env(tmp_path)


def instant_sleep(record):
    async def sleep(seconds):
        if record is not None:
            record.append(seconds)
        await asyncio.sleep(0)
    return sleep


# ─────────────────────────────── документы агентов и шлюз-заглушка ───────────────────────────────

def scores_template(role: str, value: float = 7) -> dict:
    cid = ROLE_CRITERION[role]
    return {
        "schema_version": "1", "kind": "scores", "run_id": "X", "submission_id": "X", "role": role, "rubric_version": 1,
        "scores": [{"criterion_id": cid, "status": "scored", "score": value, "max_score": 10,
                    "justification": "Есть тесты и разделение слоёв.",
                    "evidence": [{"kind": "file", "ref": "api/routes.py:40-88"}], "confidence": 0.8}],
        "flags": [],
    }


def reports(value: float = 7) -> dict:
    return {role: scores_template(role, value) for role in ROLES5}


def ux_doc(project_id: str = PID, metrics=None) -> dict:
    return {"schema_version": "1", "kind": "ux_metrics", "project_id": project_id,
            "metrics": metrics if metrics is not None else [
                {"name": "Время до первого действия", "how_to_measure": "секундомер", "good_looks_like": "< 5 с"}]}


def scripted(env: Env, *, value: float = 7, ux=..., delay: float = 0.0, write_delay: float = 0.0, fail_first=None,
             raise_roles=(), tokens=None, **kw):
    """Заглушка шлюза поверх FakeAgentGateway: журнал вызовов, метрики UX для project-level задачи, сбои по счёту."""
    from dataclasses import replace

    from app.services.gateway import FakeAgentGateway, RoleResult

    class ScriptedGateway(FakeAgentGateway):
        def __init__(self):
            super().__init__(env.data_dir, reports(value), **kw)
            self.log: list[tuple] = []
            self.counts: dict = defaultdict(int)
            self.inflight: dict = defaultdict(int)
            self.max_subs = 0
            self.ux = ux_doc() if ux is ... else ux

        async def run_role(self, run):
            key = (run.submission_id, run.role)
            if run.submission_id is None:
                self.calls.append(run)                          # super().run_role для метрик UX не вызывается
            self.log.append(("start", run.role, run.submission_id, run.attempt))
            self.inflight[run.submission_id] += 1
            self.max_subs = max(self.max_subs, sum(1 for s, n in self.inflight.items() if n and s is not None))
            try:
                if delay:
                    await asyncio.sleep(delay)
                await asyncio.sleep(0)
                self.counts[key] += 1
                if run.role in raise_roles:
                    raise RuntimeError("boom /Users/secret/path token=abc")
                if self.counts[key] <= (fail_first or {}).get(run.role, 0):
                    return RoleResult(status="failed", hermes_run_id="h-flaky", reason="flaky")
                if run.role == "design" and run.submission_id is None:
                    if self.ux is None:
                        return RoleResult(status="completed", hermes_run_id="h-ux")
                    target = env.data_dir / "runs" / run.run_id / "reports"
                    target.mkdir(parents=True, exist_ok=True)
                    (target / "design.json").write_text(json.dumps(self.ux), encoding="utf-8")
                    result = RoleResult(status="completed", hermes_run_id="h-ux")
                else:
                    result = await super().run_role(run)
                if write_delay:
                    await asyncio.sleep(write_delay)
                if tokens and result.status == "completed":
                    result = replace(result, tokens_in=tokens[0], tokens_out=tokens[1], provider="prov", model="mod")
                return result
            finally:
                self.inflight[run.submission_id] -= 1
                self.log.append(("end", run.role, run.submission_id, run.attempt))

    return ScriptedGateway()


# ─────────────────────────────── главное: сбой одной роли не валит остальные ───────────────────────────────

def test_failed_role_gives_no_data_and_other_roles_are_scored(env):
    run = env.create()
    sleeps: list = []
    gateway = scripted(env, fail_roles=["code"])
    env.execute(run["id"], gateway, sleep=instant_sleep(sleeps))

    for sub in (S1, S2):
        scores = env.scores(sub)
        code = scores["C_CODE"][-1]
        assert code["status"] == "no_data" and code["no_data_reason"] == "agent_failure" and code["score"] is None
        for role in ("business", "design", "critic-uniqueness", "critic-honesty"):
            row = scores[ROLE_CRITERION[role]][-1]
            assert row["status"] == "scored" and row["score"] == 7, role
        flags = env.rows("SELECT type FROM flag WHERE submission_id = :s", s=sub)
        assert [f["type"] for f in flags] == ["agent_failure"]
        (task,) = env.tasks(run["id"], "code", sub)
        assert task["state"] == "no_data" and task["attempt"] == 3 and task["reason"] == "simulated_failure"
        assert task["finished_at"] is not None
    assert sorted(sleeps) == [2, 2, 4, 4]                       # 2 с и 4 с между попытками, по каждой работе
    code_attempts = [call.attempt for call in gateway.calls if call.role == "code"]
    assert sorted(code_attempts) == [1, 1, 2, 2, 3, 3]
    done = [t for t in env.tasks(run["id"]) if t["state"] == "done"]
    assert len(done) == 9                                       # 4 роли × 2 работы + метрики UX
    finished = env.run(run["id"])
    assert finished["status"] == "partial" and finished["finished_at"] is not None


def test_all_roles_ok_completes_run_and_project_results(env):
    run = env.create()
    assert run["status"] == "queued" and env.project_status() == "evaluating"
    gateway = scripted(env)
    env.execute(run["id"], gateway)

    finished = env.run(run["id"])
    assert finished["status"] == "completed" and finished["finished_at"] is not None
    assert finished["tokens_in"] is None and finished["tokens_out"] is None and finished["cost_usd"] is None
    assert env.project_status() == "results"
    assert {t["state"] for t in env.tasks(run["id"])} == {"done"}
    for sub in (S1, S2):
        assert {cid for cid in env.scores(sub)} == {"C_CODE", "C_BIZ", "C_DES", "C_UNI", "C_HON"}   # human — не агент
    assert {t["attempt"] for t in env.tasks(run["id"])} == {1}


def test_critic_honesty_starts_after_all_other_roles_of_that_submission(env):
    run = env.create()
    gateway = scripted(env, delay=0.01)
    env.execute(run["id"], gateway)
    for sub in (S1, S2):
        events = [e for e in gateway.log if e[2] == sub]
        honesty_start = next(i for i, e in enumerate(events) if e[:2] == ("start", "critic-honesty"))
        others_end = [i for i, e in enumerate(events) if e[0] == "end" and e[1] != "critic-honesty"]
        assert len(others_end) == 4 and max(others_end) < honesty_start


def test_honesty_not_enabled_graph_ends_after_first_roles(env):
    env.sql("UPDATE project SET agents = :a WHERE id = :p", a=json.dumps(["code", "business"]), p=PID)
    run = env.create()
    assert sorted({t["role"] for t in env.tasks(run["id"])}) == ["business", "code"]
    assert len(env.tasks(run["id"])) == 4                       # без project-level задачи: роли design нет
    gateway = scripted(env)
    env.execute(run["id"], gateway)
    assert env.run(run["id"])["status"] == "completed"
    assert {c.role for c in gateway.calls} == {"code", "business"}


def test_run_without_any_done_task_is_failed(env):
    run = env.create(roles=["code"])
    env.execute(run["id"], scripted(env, fail_roles=["code"]))
    assert env.run(run["id"])["status"] == "failed"
    assert env.project_status() == "results"


# ─────────────────────────────── метрики UX ───────────────────────────────

def test_ux_metrics_task_runs_once_before_submission_design(env):
    run = env.create()
    ux_tasks = env.tasks(run["id"], "design", None)
    assert len(ux_tasks) == 1 and ux_tasks[0]["state"] == "queued"
    gateway = scripted(env, delay=0.01)
    env.execute(run["id"], gateway)

    metrics = env.rows("SELECT * FROM ux_metrics WHERE project_id = :p", p=PID)
    assert len(metrics) == 1
    stored = metrics[0]["metrics"]
    stored = json.loads(stored) if isinstance(stored, str) else stored
    assert stored == ux_doc()["metrics"]
    ux_calls = [e for e in gateway.log if e[1] == "design" and e[2] is None]
    assert [e[0] for e in ux_calls] == ["start", "end"]
    ux_end = gateway.log.index(("end", "design", None, 1))
    for sub in (S1, S2):
        assert gateway.log.index(("start", "design", sub, 1)) > ux_end
    first_call = next(c for c in gateway.calls if c.submission_id is None)
    assert first_call.workdir == f"projects/{PID}"
    assert (env.tasks(run["id"], "design", None)[0]["state"]) == "done"


def test_second_run_does_not_repeat_ux_metrics(env):
    first = env.create()
    env.execute(first["id"], scripted(env))
    second = env.create()
    assert env.tasks(second["id"], "design", None) == []
    gateway = scripted(env)
    env.execute(second["id"], gateway)
    assert not [c for c in gateway.calls if c.submission_id is None]
    assert len(env.rows("SELECT * FROM ux_metrics")) == 1


def test_invalid_ux_metrics_give_no_data_but_submissions_are_scored(env):
    run = env.create()
    env.execute(run["id"], scripted(env, ux=ux_doc(metrics=[])))
    assert env.rows("SELECT * FROM ux_metrics") == []
    (ux_task,) = env.tasks(run["id"], "design", None)
    assert ux_task["state"] == "no_data" and ux_task["reason"]
    for sub in (S1, S2):
        assert env.scores(sub)["C_DES"][-1]["status"] == "scored"
    assert env.run(run["id"])["status"] == "partial"


def test_ux_metrics_for_another_project_are_rejected(env):
    run = env.create()
    env.execute(run["id"], scripted(env, ux=ux_doc(project_id=OTHER_PID)))
    assert env.rows("SELECT * FROM ux_metrics") == []
    assert env.tasks(run["id"], "design", None)[0]["state"] == "no_data"


def test_ux_metrics_fallback_to_project_file(env):
    run = env.create()
    target = env.data_dir / "projects" / PID
    target.mkdir(parents=True, exist_ok=True)
    (target / "ux-metrics.json").write_text(json.dumps(ux_doc()), encoding="utf-8")
    env.execute(run["id"], scripted(env, ux=None))              # шлюз не кладёт отчёт design.json для метрик
    assert len(env.rows("SELECT * FROM ux_metrics WHERE project_id = :p", p=PID)) == 1


# ─────────────────────────────── повторы, таймаут, метаданные ───────────────────────────────

def test_flaky_role_is_retried_and_succeeds(env):
    run = env.create(roles=["code"])
    sleeps: list = []
    env.execute(run["id"], scripted(env, fail_first={"code": 1}), sleep=instant_sleep(sleeps))
    for sub in (S1, S2):
        (task,) = env.tasks(run["id"], "code", sub)
        assert task["state"] == "done" and task["attempt"] == 2
        assert env.scores(sub)["C_CODE"][-1]["status"] == "scored"
    assert sleeps == [2, 2]
    assert env.run(run["id"])["status"] == "completed"


def test_timeout_role_ends_as_no_data_with_reason_timeout(env):
    run = env.create(roles=["business"])
    env.execute(run["id"], scripted(env, timeout_roles=["business"]))
    for task in env.tasks(run["id"], "business"):
        assert task["state"] == "no_data" and task["reason"] == "timeout" and task["attempt"] == 3
    assert env.scores(S1)["C_BIZ"][-1]["no_data_reason"] == "agent_failure"


def test_task_metadata_and_token_sums_are_saved(env):
    run = env.create(roles=["code"])
    env.execute(run["id"], scripted(env, tokens=(100, 40)))
    for task in env.tasks(run["id"], "code"):
        assert task["state"] == "done" and task["hermes_run_id"]
        assert task["tokens_in"] == 100 and task["tokens_out"] == 40
        assert task["provider"] == "prov" and task["model"] == "mod"
        assert task["started_at"] is not None and task["finished_at"] is not None
    finished = env.run(run["id"])
    assert finished["tokens_in"] == 200 and finished["tokens_out"] == 80 and finished["cost_usd"] is None


def test_tokens_stay_null_when_provider_gave_none(env):
    run = env.create(roles=["code"])
    env.execute(run["id"], scripted(env))
    assert all(t["tokens_in"] is None and t["tokens_out"] is None for t in env.tasks(run["id"]))


def test_gateway_exception_is_a_failed_attempt_and_run_finishes(env, caplog):
    caplog.set_level(logging.ERROR)
    run = env.create(roles=["code", "business"])
    env.execute(run["id"], scripted(env, raise_roles=["code"]))
    for task in env.tasks(run["id"], "code"):
        assert task["state"] == "no_data" and task["attempt"] == 3
        assert "/Users/secret" not in (task["reason"] or "") and "token=abc" not in (task["reason"] or "")
    assert env.scores(S1)["C_BIZ"][-1]["status"] == "scored"
    assert env.run(run["id"])["status"] == "partial"
    logged = " ".join(str(v) for r in caplog.records for v in (r.getMessage(), *r.__dict__.values()))
    assert "/Users/secret" not in logged and "token=abc" not in logged


def test_unexpected_error_in_task_marks_it_failed_and_does_not_hang(env, caplog, monkeypatch):
    from app.services import orchestrator

    caplog.set_level(logging.ERROR)

    def broken(*args, **kwargs):
        raise RuntimeError("db exploded at /Users/secret/db.sqlite")

    run = env.create(roles=["code", "business"])
    monkeypatch.setattr(orchestrator, "ingest_report", broken)
    env.execute(run["id"], scripted(env))
    tasks = env.tasks(run["id"])
    assert {t["state"] for t in tasks} == {"failed"}
    assert all(t["reason"] and "/Users/secret" not in t["reason"] for t in tasks)
    assert env.run(run["id"])["status"] == "failed" and env.run(run["id"])["finished_at"] is not None
    assert any(r.levelno >= logging.ERROR for r in caplog.records)
    assert "/Users/secret" not in " ".join(str(v) for r in caplog.records for v in (r.getMessage(), *r.__dict__.values()))


# ─────────────────────────────── параллелизм ───────────────────────────────

def test_semaphore_limits_parallel_submissions(env):
    for i in range(5, 9):
        env.sql("INSERT INTO submission (id, project_id, team_name, intake_status, version, created_at) "
                "VALUES (:id, :p, :id, 'ready', 1, :ts)", id=f"SUBM000000000000000000000{i}", p=PID, ts=TS)
    run = env.create(roles=["code", "business"])
    gateway = scripted(env, delay=0.01)
    env.execute(run["id"], gateway, max_parallel=2, serialize_reports=False)
    # без очередности приёма отчёты одной роли у разных работ перекрываются (общий путь) — здесь важен только
    # параллелизм, поэтому итог прогона не проверяется: он обязан лишь завершиться
    assert env.run(run["id"])["status"] in ("completed", "partial", "failed")
    assert 1 <= gateway.max_subs <= 2
    run2 = env.create(roles=["code", "business"])
    gateway2 = scripted(env, delay=0.01)
    env.execute(run2["id"], gateway2, max_parallel=6, serialize_reports=False)
    assert gateway2.max_subs >= 3


def test_same_role_reports_of_parallel_submissions_do_not_clash(env):
    """Отчёт роли лежит в ``runs/<run_id>/reports/<role>.json`` — общий для всех работ прогона: запись и приём
    одной роли у разных работ не должны перекрываться, иначе приём прочитает чужой отчёт."""
    run = env.create(roles=["code"])
    env.execute(run["id"], scripted(env, write_delay=0.02))
    for sub in (S1, S2):
        assert env.scores(sub)["C_CODE"][-1]["status"] == "scored"
    assert env.rows("SELECT * FROM flag") == []


# ─────────────────────────────── события и чат ───────────────────────────────

def drain(bus) -> list:
    async def collect():
        subscription = bus.subscribe(PID, last_event_id=0)
        events = []
        while True:
            try:
                events.append(await asyncio.wait_for(subscription.__anext__(), 0.05))
            except (asyncio.TimeoutError, StopAsyncIteration):
                break
        await subscription.aclose()
        return events

    return asyncio.run(collect())


def test_events_and_system_message_are_published(env):
    run = env.create(roles=["code"])
    env.execute(run["id"], scripted(env))
    events = drain(env.bus)
    by_type: dict = defaultdict(list)
    for event in events:
        by_type[event.type].append(event.data)

    progress = by_type["run.progress"]
    assert progress and all(set(p) == {"run_id", "submission_id", "role", "state", "attempt"} for p in progress)
    assert {p["state"] for p in progress} >= {"running", "done"}
    assert all(p["run_id"] == run["id"] and p["role"] == "code" for p in progress)
    assert {(s["submission_id"], s["criterion_id"]) for s in by_type["score.changed"]} == {(S1, "C_CODE"), (S2, "C_CODE")}
    assert by_type["run.completed"] == [{"run_id": run["id"], "status": "completed"}]
    messages = env.rows("SELECT * FROM message WHERE project_id = :p AND kind = 'run_completed'", p=PID)
    assert len(messages) == 1 and messages[0]["author"] == "system" and messages[0]["text"].startswith("Оценка завершена")
    assert by_type["message.created"] == [{"message_id": messages[0]["id"]}]


def test_final_failure_publishes_no_data_state(env):
    run = env.create(roles=["code"])
    env.execute(run["id"], scripted(env, fail_roles=["code"]))
    states = [e.data["state"] for e in drain(env.bus) if e.type == "run.progress"]
    assert "no_data" in states
    attempts = {e.data["attempt"] for e in drain(env.bus) if e.type == "run.progress" and e.data["submission_id"] == S1}
    assert attempts == {1, 2, 3}


# ─────────────────────────────── создание прогона ───────────────────────────────

def test_create_run_builds_tasks_and_view(env):
    run = env.create()
    assert run["project_id"] == PID and run["status"] == "queued" and run["rubric_version"] == 1
    assert run["finished_at"] is None and run["tokens_in"] is None and run["cost_usd"] is None
    pairs = {(t["submission_id"], t["role"]) for t in run["tasks"]}
    assert pairs == {(sid, role) for sid in (S1, S2) for role in ROLES5} | {(None, "design")}
    assert all(t["state"] == "queued" and t["attempt"] == 0 for t in run["tasks"])
    row = env.run(run["id"])
    requested = row["requested"]
    assert (json.loads(requested) if isinstance(requested, str) else requested) is not None
    assert len(env.rows("SELECT * FROM run_task WHERE run_id = :r", r=run["id"])) == 11


def test_create_run_writes_confirmed_rubric_file(env):
    run = env.create()
    document = json.loads((env.data_dir / "projects" / PID / "rubric.json").read_text(encoding="utf-8"))
    assert document["rubric_version"] == run["rubric_version"] == 1
    by_id = {c["id"]: c for c in document["criteria"]}
    assert set(by_id) == set(CRITERIA)
    code = by_id["C_CODE"]
    assert {"id", "name", "weight", "max_score", "agent", "anchors"} <= set(code)
    assert code["agent"] == "code" and code["weight"] == 2 and code["max_score"] == 10
    assert code["anchors"] == [{"score": 0, "meaning": "нет"}, {"score": 10, "meaning": "отлично"}]


def test_create_run_refuses_symlinked_project_directory(env, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (env.data_dir / "projects").symlink_to(outside, target_is_directory=True)
    from app.services.storage import UnsafePath

    with pytest.raises(UnsafePath):
        env.create()
    assert list(outside.iterdir()) == []
    assert env.rows("SELECT * FROM run") == []                  # транзакция откатилась
    assert env.project_status() == "intake"


def test_project_status_transitions_on_create(env):
    for start in ("setup", "intake", "results", "evaluating"):
        env.sql("UPDATE project SET status = :s WHERE id = :p", s=start, p=PID)
        env.sql("UPDATE run SET status = 'completed'")
        env.sql("UPDATE run_task SET state = 'done'")
        env.create()
        assert env.project_status() == "evaluating", start


def test_create_run_for_archived_project_is_a_conflict(env):
    from app.services import orchestrator

    env.sql("UPDATE project SET status = 'archived' WHERE id = :p", p=PID)
    with pytest.raises(orchestrator.RunConflict):
        env.create()


def test_criterion_ids_select_only_owning_roles(env):
    run = env.create(criterion_ids=["C_CODE", "C_HUM"])
    assert {t["role"] for t in run["tasks"]} == {"code"}
    assert {t["submission_id"] for t in run["tasks"]} == {S1, S2}


def test_roles_are_intersected_with_project_agents(env):
    env.sql("UPDATE project SET agents = :a WHERE id = :p", a=json.dumps(["code", "business", "human"]), p=PID)
    run = env.create(roles=["business", "design"])
    assert {t["role"] for t in run["tasks"]} == {"business"}


def test_unknown_criterion_and_foreign_submission_are_invalid(env):
    from app.services import orchestrator

    with pytest.raises(orchestrator.InvalidRunRequest):
        env.create(criterion_ids=["NOPE"])
    with pytest.raises(orchestrator.InvalidRunRequest):
        env.create(submission_ids=[FOREIGN_SUB])
    with pytest.raises(orchestrator.InvalidRunRequest):
        env.create(submission_ids=[S4_DELETED])
    assert env.rows("SELECT * FROM run") == []


def test_no_ready_submissions_and_active_run_are_conflicts(env):
    from app.services import orchestrator

    with pytest.raises(orchestrator.RunConflict):
        env.create(submission_ids=[S3_PENDING])
    first = env.create()
    with pytest.raises(orchestrator.RunConflict):
        env.create()
    assert len(env.rows("SELECT * FROM run")) == 1 and first["status"] == "queued"
    env.sql("UPDATE submission SET intake_status = 'pending'")
    env.sql("UPDATE run SET status = 'completed'")
    with pytest.raises(orchestrator.RunConflict):
        env.create()


def test_unconfirmed_rubric_raises(env):
    from app.services.rubric import RubricNotConfirmed

    env.sql("UPDATE rubric SET status = 'draft'")
    with pytest.raises(RubricNotConfirmed):
        env.create()


# ─────────────────────────────── перезапуск (FR-024) ───────────────────────────────

def test_restart_one_submission_and_role_keeps_old_scores(env):
    first = env.create()
    env.execute(first["id"], scripted(env, value=7))
    second = env.create(submission_ids=[S1], roles=["code"])
    assert [(t["submission_id"], t["role"]) for t in second["tasks"]] == [(S1, "code")]
    env.execute(second["id"], scripted(env, value=9))

    s1_code = env.scores(S1)["C_CODE"]
    assert [r["score"] for r in s1_code] == [7, 9] and s1_code[0]["created_at"] < s1_code[1]["created_at"]
    assert [r["score"] for r in env.scores(S2)["C_CODE"]] == [7]
    assert len(env.scores(S1)["C_BIZ"]) == 1
    requested = env.run(second["id"])["requested"]
    requested = json.loads(requested) if isinstance(requested, str) else requested
    assert requested["submission_ids"] == [S1] and requested["roles"] == ["code"]


def test_restart_by_criterion_does_not_touch_other_criteria_of_the_role(env):
    """Находка ревью (P0, данные): перезапуск по критерию пишет оценки только выбранных критериев роли; остальные
    критерии роли не получают новых строк (в том числе ``no_data``), иначе новая запись затёрла бы старую оценку."""
    env.sql("INSERT INTO criterion (id, rubric_id, position, name, description, weight, max_score, agent) "
            "VALUES ('C_CODE2', 'RUBRIC_1', 9, 'Второй критерий кода', '', 1, 10, 'code')")
    both = scores_template("code", 7)
    both["scores"].append(dict(both["scores"][0], criterion_id="C_CODE2", score=5))
    first = env.create(roles=["code"])
    gateway = scripted(env)
    gateway._reports["code"] = both
    env.execute(first["id"], gateway)
    assert [r["score"] for r in env.scores(S1)["C_CODE2"]] == [5]

    second = env.create(roles=["code"], criterion_ids=["C_CODE"])
    only = scripted(env, value=9)                               # агент отвечает только по выбранному критерию
    env.execute(second["id"], only)

    assert [r["score"] for r in env.scores(S1)["C_CODE"]] == [7, 9]
    assert [r["score"] for r in env.scores(S1)["C_CODE2"]] == [5]          # ни новой оценки, ни no_data
    assert all(t["state"] == "done" for t in env.tasks(second["id"]))
    instructions = only.calls[0].instructions
    assert "C_CODE:" in instructions and "C_CODE2" not in instructions     # агенту перечислены только выбранные


# ─────────────────────────────── завершение процесса ───────────────────────────────

def test_recover_interrupted_fails_running_and_queued_work(env):
    from app.services.orchestrator import recover_interrupted

    run = env.create()
    env.sql("UPDATE run SET status = 'running' WHERE id = :r", r=run["id"])
    tasks = env.tasks(run["id"])
    env.sql("UPDATE run_task SET state = 'running', attempt = 1 WHERE id = :i", i=tasks[0]["id"])
    env.sql("UPDATE run_task SET state = 'done', attempt = 1 WHERE id = :i", i=tasks[1]["id"])
    env.sql("INSERT INTO run (id, project_id, rubric_version, status, created_at, finished_at) "
            "VALUES ('RUNDONE', :p, 1, 'completed', :ts, :ts)", p=PID, ts=TS)

    assert recover_interrupted(env.factory) == 1
    after = {t["id"]: t for t in env.tasks(run["id"])}
    assert after[tasks[0]["id"]]["state"] == "failed" and after[tasks[0]["id"]]["reason"] == "interrupted"
    assert after[tasks[1]["id"]]["state"] == "done"
    queued_left = [t for t in after.values() if t["state"] == "queued"]
    assert queued_left == []
    assert all(t["reason"] == "interrupted" for t in after.values() if t["id"] != tasks[1]["id"])
    assert all(t["finished_at"] is not None for t in after.values() if t["id"] != tasks[1]["id"])
    finished = env.run(run["id"])
    assert finished["status"] == "failed" and finished["finished_at"] is not None
    assert env.run("RUNDONE")["status"] == "completed"
    assert env.project_status() == "results"
    assert recover_interrupted(env.factory) == 0
    env.create()                                                # после восстановления можно запускать заново
