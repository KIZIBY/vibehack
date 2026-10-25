"""T027: рубрика (``app.services.rubric``, ``app.routers.rubric``). Тесты написаны ДО реализации (RED).

Контракт (задача T027, openapi.yaml: Rubric / RubricState / CriterionInput, contracts/agent-run.md §1–§3):
- ``GET  /api/v1/projects/{id}/rubric`` -> ``{"current", "versions"}``: ``current`` — последняя ``confirmed``-версия,
  иначе последний ``draft``, иначе ``null``; ``versions`` — все версии, новые сверху; проекта нет -> 404;
- ``PUT  …/rubric`` ``{criteria, expected_version}`` — НОВАЯ версия-черновик ``latest+1``; ``expected_version`` обязан
  равняться номеру последней версии (0, если версий нет), иначе 409 ``version_conflict``; критерии новой версии
  получают новые id; невалидное (нет критериев, weight/max_score <= 0, чужая роль, повтор названия без учёта
  регистра) -> 422 ``invalid``; подтверждённая версия не меняется;
- ``POST …/rubric/confirm`` ``{version}`` — подтверждает ПОСЛЕДНЮЮ версию-черновик (иначе 409), прежняя
  подтверждённая становится ``superseded``, ``project.rubric_confirmed_version`` и ``project.version`` обновляются;
- ``POST …/rubric/draft`` -> 202; нет вводного ``brief`` со статусом ``extracted`` -> 409; уже строится -> 409;
  шлюз ``app.state.gateway`` не настроен -> 503; построение идёт в фоне со своей сессией;
- ``build_draft(session_factory, gateway, data_dir, project_id) -> dict | str``: роль ``rubric``; документ
  ``kind=rubric_draft`` читается из ``projects/<id>/rubric-draft.json`` (запасной путь — отчёт шлюза
  ``runs/<run_id>/reports/rubric__project.json``, куда пишет ``FakeAgentGateway``; scope = ``project``), проверяется по
  ``agent-report.schema.json``; при сбое версия не создаётся, возвращается причина строкой, в журнал — ERROR;
- ``require_confirmed_rubric(session, project_id) -> int`` / ``RubricNotConfirmed`` (запуск оценки без
  подтверждённой рубрики невозможен); ``changed_criteria(session, project_id, old, new) -> set[str]``.

Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import asyncio
import json
import logging
import threading
from pathlib import Path

import pytest
import sqlalchemy as sa
from alembic import command
from alembic.config import Config

REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / "backend"
TS = "2026-01-01 00:00:00.000000"
PID = "PROJ0000000000000000000001"
DEMO_USER = "demo"
DEMO_PW = "demo-pass-for-tests-0001"
SESSION_SECRET = "test-session-secret-0000000000000001"
BASE = "/api/v1/projects"


# ─────────────────────────────── хелперы ───────────────────────────────

def migrated_url(tmp_path: Path) -> str:
    url = f"sqlite:///{tmp_path / 'db.sqlite'}"
    cfg = Config(str(BACKEND / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND / "migrations"))
    cfg.set_main_option("sqlalchemy.url", url)
    command.upgrade(cfg, "head")
    return url


class Env:
    """Приложение на временной SQLite с миграциями + прямой доступ к БД для подготовки и проверки данных."""

    def __init__(self, tmp_path: Path, *, gateway=None):
        from app.config import load_settings
        from app.main import create_app

        self.tmp = tmp_path
        self.data_dir = tmp_path / "data"
        self.data_dir.mkdir()
        self.url = migrated_url(tmp_path)
        env = {
            "JUDGE_DATABASE_URL": self.url, "JUDGE_DATA_DIR": str(self.data_dir),
            "JUDGE_DEMO_USER": DEMO_USER, "JUDGE_DEMO_PASSWORD": DEMO_PW, "JUDGE_SESSION_SECRET": SESSION_SECRET,
        }
        self.app = create_app(load_settings(env))
        if gateway is not None:
            self.app.state.gateway = gateway
        self.engine = self.app.state.engine
        self.factory = self.app.state.session_factory

    def client(self, *, auth: bool = True):
        from fastapi.testclient import TestClient

        client = TestClient(self.app, raise_server_exceptions=False)
        if auth:
            client.cookies.set("session", self.app.state.sessions.issue(DEMO_USER))
        return client

    def sql(self, statement: str, **params):
        with self.engine.begin() as conn:
            return conn.execute(sa.text(statement), params)

    def rows(self, statement: str, **params) -> list[dict]:
        with self.engine.connect() as conn:
            return [dict(r) for r in conn.execute(sa.text(statement), params).mappings()]

    def add_project(self, pid: str = PID) -> str:
        self.sql(
            "INSERT INTO project (id, name, type, status, agents, required_materials, retention_days, "
            "last_activity_at, version, created_at, updated_at) "
            "VALUES (:id, 'Demo', 'other', 'setup', '[]', '{}', 7, :ts, 1, :ts, :ts)", id=pid, ts=TS)
        return pid

    def add_brief(self, status: str = "extracted", pid: str = PID, bid: str = "BRIEF0000000000000000000001") -> None:
        self.sql(
            "INSERT INTO brief (id, project_id, name, source, status, created_at) "
            "VALUES (:id, :pid, 'brief.md', 'upload', :status, :ts)", id=bid, pid=pid, status=status, ts=TS)

    def versions(self, pid: str = PID) -> list[int]:
        return [r["version"] for r in self.rows("SELECT version FROM rubric WHERE project_id = :p ORDER BY version",
                                                p=pid)]

    def project(self, pid: str = PID) -> dict:
        return self.rows("SELECT version, rubric_confirmed_version FROM project WHERE id = :p", p=pid)[0]


def crit(name: str = "Идея", **over) -> dict:
    data = {"name": name, "description": f"Описание: {name}", "weight": 1, "max_score": 10, "agent": "business"}
    data.update(over)
    return data


def two_criteria() -> list[dict]:
    return [crit("Идея", agent="business"), crit("Реализация", agent="code", weight=2)]


@pytest.fixture
def env(tmp_path):
    e = Env(tmp_path)
    e.add_project()
    return e


def put(client, criteria, expected_version, pid: str = PID):
    return client.put(f"{BASE}/{pid}/rubric", json={"criteria": criteria, "expected_version": expected_version})


def confirm(client, version, pid: str = PID):
    return client.post(f"{BASE}/{pid}/rubric/confirm", json={"version": version})


def error_code(resp) -> str:
    return resp.json()["error"]["code"]


def draft_doc(pid: str = PID, **over) -> dict:
    doc = {
        "schema_version": "1", "kind": "rubric_draft", "project_id": pid,
        "criteria": [
            {"name": "Идея", "description": "Новизна и польза", "weight": 1, "max_score": 10, "agent": "business",
             "source_ref": "brief.md, раздел 2",
             "anchors": [{"score": 0, "meaning": "нет идеи"}, {"score": 10, "meaning": "сильная идея"}]},
            {"name": "Код", "description": "Качество кода", "weight": 1, "max_score": 10, "agent": "code",
             "source_ref": "brief.md, раздел 3"},
        ],
        "weights_were_missing": True,
    }
    doc.update(over)
    return doc


def write_project_draft(data_dir: Path, doc, pid: str = PID) -> None:
    target = data_dir / "projects" / pid / "rubric-draft.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(doc if isinstance(doc, str) else json.dumps(doc, ensure_ascii=False), encoding="utf-8")


def project_file_gateway(data_dir: Path, doc, pid: str = PID):
    """Шлюз, который кладёт документ туда, куда по контракту §1 его кладёт плагин роли rubric."""
    from app.services.gateway import FakeAgentGateway, RoleResult

    class Gateway(FakeAgentGateway):
        async def run_role(self, run):
            self.calls.append(run)
            write_project_draft(data_dir, doc, pid)
            return RoleResult(status="completed", hermes_run_id="fake-1")

    return Gateway(data_dir)


def run_build(env: Env, gateway, pid: str = PID):
    from app.services.rubric import build_draft

    return asyncio.run(build_draft(env.factory, gateway, env.data_dir, pid))


# ─────────────────────────────── GET / PUT ───────────────────────────────

def test_services_package_init_is_single_docstring_line():
    text = (BACKEND / "app" / "services" / "__init__.py").read_text(encoding="utf-8")
    assert text.strip() == '"""Сервисы приложения."""'


def test_get_rubric_unknown_project_is_404(env):
    resp = env.client().get(f"{BASE}/NOPE/rubric")
    assert resp.status_code == 404
    assert error_code(resp) == "not_found"


def test_get_rubric_requires_session(env):
    assert env.client(auth=False).get(f"{BASE}/{PID}/rubric").status_code == 401


def test_get_rubric_empty_project(env):
    resp = env.client().get(f"{BASE}/{PID}/rubric")
    assert resp.status_code == 200
    assert resp.json() == {"current": None, "versions": []}


def test_soft_deleted_project_is_404(env):
    env.sql("UPDATE project SET deleted_at = :ts WHERE id = :p", ts=TS, p=PID)
    assert env.client().get(f"{BASE}/{PID}/rubric").status_code == 404
    assert put(env.client(), two_criteria(), 0).status_code == 404


def test_put_creates_first_draft_version(env):
    resp = put(env.client(), two_criteria(), 0)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["version"] == 1 and body["status"] == "draft"
    assert body["confirmed_at"] is None and body["created_at"]
    assert [c["name"] for c in body["criteria"]] == ["Идея", "Реализация"]
    assert all(len(c["id"]) == 26 for c in body["criteria"])
    assert body["criteria"][1]["weight"] == 2 and body["criteria"][1]["agent"] == "code"
    assert env.versions() == [1]


def test_put_keeps_anchors_and_description(env):
    anchors = [{"score": 0, "meaning": "плохо"}, {"score": 10, "meaning": "отлично"}]
    body = put(env.client(), [crit("Идея", anchors=anchors, description="Подробно")], 0).json()
    assert body["criteria"][0]["anchors"] == anchors
    assert body["criteria"][0]["description"] == "Подробно"
    again = env.client().get(f"{BASE}/{PID}/rubric").json()["current"]
    assert again["criteria"][0]["anchors"] == anchors


def test_get_after_put_returns_current_draft_and_versions_newest_first(env):
    client = env.client()
    put(client, two_criteria(), 0)
    put(client, two_criteria(), 1)
    state = client.get(f"{BASE}/{PID}/rubric").json()
    assert state["current"]["version"] == 2 and state["current"]["status"] == "draft"
    assert [v["version"] for v in state["versions"]] == [2, 1]
    assert set(state["versions"][0]) >= {"version", "status", "created_at"}


def test_put_with_stale_expected_version_is_409_and_creates_nothing(env):
    client = env.client()
    assert put(client, two_criteria(), 0).status_code == 200
    resp = put(client, two_criteria(), 0)
    assert resp.status_code == 409 and error_code(resp) == "version_conflict"
    assert put(client, two_criteria(), 5).status_code == 409
    assert env.versions() == [1]


def test_concurrent_puts_with_same_expected_version_exactly_one_wins(env):
    results: list[int] = []

    def worker():
        results.append(put(env.client(), two_criteria(), 0).status_code)

    threads = [threading.Thread(target=worker) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(results) == [200, 409]
    assert env.versions() == [1]


@pytest.mark.parametrize("criteria", [
    [],
    [crit(weight=0)],
    [crit(weight=-1)],
    [crit(max_score=0)],
    [crit(max_score=-5)],
    [crit(agent="rubric")],
    [crit(agent="wizard")],
    [crit(name="   ")],
    [crit(name="")],
    [crit("Идея"), crit("идея")],
    [crit("Design"), crit("DESIGN")],
    [crit(weight="5")],
    [crit(weight=True)],
    [crit(max_score="10")],
], ids=["empty", "weight0", "weight_neg", "max0", "max_neg", "role_rubric", "role_unknown", "name_blank",
        "name_empty", "dup_ru", "dup_en", "weight_str", "weight_bool", "max_str"])
def test_put_rejects_invalid_criteria_with_422(env, criteria):
    resp = put(env.client(), criteria, 0)
    assert resp.status_code == 422, resp.text
    assert error_code(resp) == "invalid"
    assert env.versions() == []


def test_put_rejects_non_finite_weight(env):
    resp = env.client().put(f"{BASE}/{PID}/rubric", content='{"criteria":[{"name":"A","weight":1e999,'
                            '"max_score":10,"agent":"code"}],"expected_version":0}',
                            headers={"content-type": "application/json"})
    assert resp.status_code == 422 and error_code(resp) == "invalid"
    assert env.versions() == []


def test_put_rejects_negative_expected_version(env):
    assert put(env.client(), two_criteria(), -1).status_code == 422


def test_put_allows_human_agent(env):
    assert put(env.client(), [crit("Защита", agent="human")], 0).status_code == 200


def test_put_ignores_client_supplied_ids_and_assigns_fresh_ones(env):
    client = env.client()
    first = put(client, two_criteria(), 0).json()
    second = put(client, [dict(c, id=first["criteria"][i]["id"]) for i, c in enumerate(two_criteria())], 1).json()
    ids_first = {c["id"] for c in first["criteria"]}
    ids_second = {c["id"] for c in second["criteria"]}
    assert len(ids_second) == 2 and not ids_first & ids_second


def test_put_after_confirm_creates_new_version_and_confirmed_stays_unchanged(env):
    client = env.client()
    put(client, two_criteria(), 0)
    assert confirm(client, 1).status_code == 200
    before = env.rows("SELECT id, name, weight, max_score, agent, description FROM criterion ORDER BY id")
    resp = put(client, [crit("Идея", weight=5)], 1)
    assert resp.status_code == 200 and resp.json()["version"] == 2 and resp.json()["status"] == "draft"
    rubric_v1 = env.rows("SELECT status, confirmed_at FROM rubric WHERE version = 1")[0]
    assert rubric_v1["status"] == "confirmed" and rubric_v1["confirmed_at"] is not None
    after = env.rows("SELECT id, name, weight, max_score, agent, description FROM criterion ORDER BY id")
    assert [r for r in after if r["id"] in {b["id"] for b in before}] == before
    assert env.project()["rubric_confirmed_version"] == 1


def test_get_prefers_confirmed_over_newer_draft(env):
    client = env.client()
    put(client, two_criteria(), 0)
    confirm(client, 1)
    put(client, [crit("Идея")], 1)
    state = client.get(f"{BASE}/{PID}/rubric").json()
    assert state["current"]["version"] == 1 and state["current"]["status"] == "confirmed"
    assert [(v["version"], v["status"]) for v in state["versions"]] == [(2, "draft"), (1, "confirmed")]


def test_weights_were_missing_is_returned(env):
    env.sql("INSERT INTO rubric (id, project_id, version, status, weights_were_missing, created_at) "
            "VALUES ('R1', :p, 1, 'draft', 1, :ts)", p=PID, ts=TS)
    env.sql("INSERT INTO criterion (id, rubric_id, position, name, description, weight, max_score, agent) "
            "VALUES ('C1', 'R1', 0, 'Идея', '', 1, 10, 'business')")
    current = env.client().get(f"{BASE}/{PID}/rubric").json()["current"]
    assert current["weights_were_missing"] is True


# ─────────────────────────────── confirm ───────────────────────────────

def test_confirm_marks_version_and_updates_project(env):
    client = env.client()
    put(client, two_criteria(), 0)
    project_before = env.project()
    resp = confirm(client, 1)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["version"] == 1 and body["status"] == "confirmed" and body["confirmed_at"]
    assert len(body["criteria"]) == 2
    project = env.project()
    assert project["rubric_confirmed_version"] == 1
    assert project["version"] == project_before["version"] + 1
    state = client.get(f"{BASE}/{PID}/rubric").json()
    assert state["current"]["status"] == "confirmed"


def test_confirm_second_version_supersedes_first(env):
    client = env.client()
    put(client, two_criteria(), 0)
    confirm(client, 1)
    put(client, two_criteria(), 1)
    assert confirm(client, 2).status_code == 200
    statuses = {r["version"]: r["status"] for r in env.rows("SELECT version, status FROM rubric")}
    assert statuses == {1: "superseded", 2: "confirmed"}
    assert env.project()["rubric_confirmed_version"] == 2


@pytest.mark.parametrize("setup, version", [
    ("none", 1),            # версий нет вообще
    ("two_drafts", 1),      # подтверждается не последняя версия
    ("confirmed", 1),       # последняя уже подтверждена
    ("one_draft", 7),       # версии не существует
])
def test_confirm_wrong_target_is_409_not_500(env, setup, version):
    client = env.client()
    if setup == "two_drafts":
        put(client, two_criteria(), 0)
        put(client, two_criteria(), 1)
    elif setup == "confirmed":
        put(client, two_criteria(), 0)
        confirm(client, 1)
    elif setup == "one_draft":
        put(client, two_criteria(), 0)
    before = env.project()
    resp = confirm(client, version)
    assert resp.status_code == 409, resp.text
    assert env.project() == before


def test_confirm_stale_draft_leaves_older_confirmed_untouched(env):
    client = env.client()
    put(client, two_criteria(), 0)
    confirm(client, 1)
    put(client, two_criteria(), 1)
    put(client, two_criteria(), 2)
    assert confirm(client, 2).status_code == 409
    assert {r["version"]: r["status"] for r in env.rows("SELECT version, status FROM rubric")} == {
        1: "confirmed", 2: "draft", 3: "draft"}
    assert env.project()["rubric_confirmed_version"] == 1


def test_confirm_validation_and_missing_project(env):
    client = env.client()
    assert client.post(f"{BASE}/{PID}/rubric/confirm", json={"version": 0}).status_code == 422
    assert client.post(f"{BASE}/{PID}/rubric/confirm", json={}).status_code == 422
    assert confirm(client, 1, pid="NOPE").status_code == 404


def test_confirm_uses_current_project_version(env):
    """project.version читается внутри транзакции: параллельная правка проекта до confirm не ломает его."""
    client = env.client()
    put(client, two_criteria(), 0)
    env.sql("UPDATE project SET version = 9 WHERE id = :p", p=PID)
    assert confirm(client, 1).status_code == 200
    assert env.project()["version"] == 10


# ─────────────────────────────── require_confirmed_rubric ───────────────────────────────

def test_rubric_not_confirmed_is_an_exception_class():
    from app.services.rubric import RubricNotConfirmed

    assert issubclass(RubricNotConfirmed, Exception)


def test_require_confirmed_rubric_raises_without_confirmed_version(env):
    from app.services.rubric import RubricNotConfirmed, require_confirmed_rubric

    with env.factory() as session:
        with pytest.raises(RubricNotConfirmed):
            require_confirmed_rubric(session, PID)
    put(env.client(), two_criteria(), 0)   # черновик не считается подтверждённой рубрикой
    with env.factory() as session:
        with pytest.raises(RubricNotConfirmed):
            require_confirmed_rubric(session, PID)


def test_require_confirmed_rubric_returns_confirmed_version(env):
    from app.services.rubric import require_confirmed_rubric

    client = env.client()
    put(client, two_criteria(), 0)
    confirm(client, 1)
    put(client, two_criteria(), 1)   # новый черновик не отменяет подтверждённую версию
    with env.factory() as session:
        assert require_confirmed_rubric(session, PID) == 1
    confirm(client, 2)
    with env.factory() as session:
        assert require_confirmed_rubric(session, PID) == 2


def test_require_confirmed_rubric_unknown_project_raises(env):
    from app.services.rubric import RubricNotConfirmed, require_confirmed_rubric

    with env.factory() as session:
        with pytest.raises(RubricNotConfirmed):
            require_confirmed_rubric(session, "NOPE")


# ─────────────────────────────── changed_criteria ───────────────────────────────

def changed(env, old: int, new: int) -> set[str]:
    from app.services.rubric import changed_criteria

    with env.factory() as session:
        return changed_criteria(session, PID, old, new)


def test_changed_criteria_detects_meaning_changes_only(env):
    client = env.client()
    base = [crit("Идея", description="Старое", max_score=10, agent="business"),
            crit("Код", description="Код", max_score=10, agent="code"),
            crit("Дизайн", description="Дизайн", max_score=10, agent="design"),
            crit("Вес", description="Вес", max_score=10, agent="code", weight=1),
            crit("Без изменений", description="Так же", max_score=5, agent="code"),
            crit("Удалённый", description="x", agent="code")]
    put(client, base, 0)
    new = [crit("идея", description="Новое", max_score=10, agent="business"),       # описание (имя в другом регистре)
           crit("Код", description="Код", max_score=20, agent="code"),              # шкала
           crit("Дизайн", description="Дизайн", max_score=10, agent="business"),    # роль
           crit("Вес", description="Вес", max_score=10, agent="code", weight=9),    # вес не считается
           crit("Без изменений", description="Так же", max_score=5, agent="code"),
           crit("Добавленный", description="y", agent="code")]
    put(client, new, 1)
    assert {n.casefold() for n in changed(env, 1, 2)} == {"идея", "код", "дизайн", "удалённый", "добавленный"}


def test_changed_criteria_identical_versions_is_empty(env):
    client = env.client()
    put(client, two_criteria(), 0)
    put(client, [dict(c, weight=7) for c in two_criteria()], 1)
    assert changed(env, 1, 2) == set()


def test_changed_criteria_ignores_surrounding_whitespace_in_description(env):
    client = env.client()
    put(client, [crit("Идея", description="Текст")], 0)
    put(client, [crit("Идея", description="  Текст ")], 1)
    assert changed(env, 1, 2) == set()


def test_changed_criteria_returns_a_set_of_names(env):
    client = env.client()
    put(client, [crit("A", agent="code")], 0)
    put(client, [crit("A", agent="design")], 1)
    result = changed(env, 1, 2)
    assert isinstance(result, set) and {n.casefold() for n in result} == {"a"}


# ─────────────────────────────── POST /rubric/draft ───────────────────────────────

def test_draft_unknown_project_is_404(tmp_path):
    from app.services.gateway import FakeAgentGateway

    e = Env(tmp_path, gateway=FakeAgentGateway(tmp_path))
    assert e.client().post(f"{BASE}/NOPE/rubric/draft").status_code == 404


@pytest.mark.parametrize("brief_status", [None, "processing", "failed", "deleted"])
def test_draft_without_extracted_brief_is_409(tmp_path, brief_status):
    from app.services.gateway import FakeAgentGateway

    gateway = FakeAgentGateway(tmp_path)
    e = Env(tmp_path, gateway=gateway)
    e.add_project()
    if brief_status:
        e.add_brief(brief_status)
    resp = e.client().post(f"{BASE}/{PID}/rubric/draft")
    assert resp.status_code == 409, resp.text
    assert gateway.calls == []


def test_draft_without_gateway_is_503(tmp_path):
    e = Env(tmp_path)
    e.add_project()
    e.add_brief()
    resp = e.client().post(f"{BASE}/{PID}/rubric/draft")
    assert resp.status_code == 503
    assert e.versions() == []


def test_draft_requires_session(tmp_path):
    from app.services.gateway import FakeAgentGateway

    e = Env(tmp_path, gateway=FakeAgentGateway(tmp_path))
    e.add_project()
    assert e.client(auth=False).post(f"{BASE}/{PID}/rubric/draft").status_code == 401


def test_draft_request_returns_202_and_builds_version_in_background(tmp_path):
    e = Env(tmp_path)
    e.add_project()
    e.add_brief()
    gateway = project_file_gateway(e.data_dir, draft_doc())
    e.app.state.gateway = gateway
    resp = e.client().post(f"{BASE}/{PID}/rubric/draft")
    assert resp.status_code == 202, resp.text
    assert [c.role for c in gateway.calls] == ["rubric"]
    state = e.client().get(f"{BASE}/{PID}/rubric").json()
    assert state["current"]["version"] == 1 and state["current"]["status"] == "draft"
    assert state["current"]["weights_were_missing"] is True
    names = [c["name"] for c in state["current"]["criteria"]]
    assert names == ["Идея", "Код"]
    first = state["current"]["criteria"][0]
    assert first["source_ref"] == "brief.md, раздел 2" and first["anchors"][1]["meaning"] == "сильная идея"


def test_draft_build_runs_in_own_session_and_new_request_allowed_afterwards(tmp_path):
    e = Env(tmp_path)
    e.add_project()
    e.add_brief()
    e.app.state.gateway = project_file_gateway(e.data_dir, draft_doc())
    client = e.client()
    assert client.post(f"{BASE}/{PID}/rubric/draft").status_code == 202
    assert client.post(f"{BASE}/{PID}/rubric/draft").status_code == 202   # защита снята после завершения
    assert e.versions() == [1, 2]


def test_draft_failure_releases_the_in_progress_guard(tmp_path):
    from app.services.gateway import FakeAgentGateway

    e = Env(tmp_path)
    e.add_project()
    e.add_brief()
    e.app.state.gateway = FakeAgentGateway(tmp_path, fail_roles=["rubric"])
    client = e.client()
    assert client.post(f"{BASE}/{PID}/rubric/draft").status_code == 202
    assert client.post(f"{BASE}/{PID}/rubric/draft").status_code == 202
    assert e.versions() == []


def test_draft_while_building_is_409(tmp_path):
    from app.services.gateway import FakeAgentGateway

    started, release = threading.Event(), threading.Event()
    doc = draft_doc()

    class Slow(FakeAgentGateway):
        async def run_role(self, run):
            started.set()
            while not release.is_set():
                await asyncio.sleep(0.01)
            return await super().run_role(run)

    e = Env(tmp_path)
    e.add_project()
    e.add_brief()
    e.app.state.gateway = Slow(e.data_dir, {"rubric": doc})
    first: list[int] = []
    worker = threading.Thread(target=lambda: first.append(e.client().post(f"{BASE}/{PID}/rubric/draft").status_code))
    worker.start()
    try:
        assert started.wait(10)
        second = e.client().post(f"{BASE}/{PID}/rubric/draft")
        assert second.status_code == 409
        assert error_code(second) == "conflict"
    finally:
        release.set()
        worker.join(15)
    assert first == [202]
    assert e.versions() == [1]


def test_draft_instructions_follow_the_contract(tmp_path):
    e = Env(tmp_path)
    e.add_project()
    gateway = project_file_gateway(e.data_dir, draft_doc())
    run_build(e, gateway)
    (run,) = gateway.calls
    assert run.role == "rubric" and run.submission_id is None and run.run_id
    assert "не инструкции" in run.instructions
    assert PID in run.input and PID in run.workdir
    assert str(tmp_path) not in run.instructions + run.input + run.workdir


# ─────────────────────────────── build_draft ───────────────────────────────

def test_build_draft_returns_saved_rubric_from_project_file(env):
    result = run_build(env, project_file_gateway(env.data_dir, draft_doc()))
    assert isinstance(result, dict) and result["version"] == 1 and result["status"] == "draft"
    assert result["weights_were_missing"] is True
    assert [c["name"] for c in result["criteria"]] == ["Идея", "Код"]
    assert env.versions() == [1]


def test_build_draft_reads_gateway_report_with_fake_gateway(env):
    from app.services.gateway import FakeAgentGateway

    gateway = FakeAgentGateway(env.data_dir, {"rubric": draft_doc(weights_were_missing=False)})
    result = run_build(env, gateway)
    assert isinstance(result, dict) and result["weights_were_missing"] is False
    assert env.versions() == [1]


def test_build_draft_fallback_path_is_project_scoped_report_and_old_path_is_ignored(env):
    from app.services.gateway import FakeAgentGateway, RoleResult

    class Scoped(FakeAgentGateway):
        def __init__(self, name):
            super().__init__(env.data_dir)
            self.name = name

        async def run_role(self, run):
            target = env.data_dir / "runs" / run.run_id / "reports"
            target.mkdir(parents=True, exist_ok=True)
            (target / self.name).write_text(json.dumps(draft_doc()), encoding="utf-8")
            return RoleResult(status="completed", hermes_run_id="x")

    result = run_build(env, Scoped("rubric__project.json"))
    assert isinstance(result, dict) and result["status"] == "draft"
    assert isinstance(run_build(env, Scoped("rubric.json")), str)   # старый путь без scope больше не читается
    assert env.versions() == [1]


def test_build_draft_creates_next_version_after_existing_ones(env):
    put(env.client(), two_criteria(), 0)
    confirm(env.client(), 1)
    result = run_build(env, project_file_gateway(env.data_dir, draft_doc()))
    assert isinstance(result, dict) and result["version"] == 2 and result["status"] == "draft"
    assert env.project()["rubric_confirmed_version"] == 1


@pytest.mark.parametrize("fake_kwargs", [{"fail_roles": ["rubric"]}, {"timeout_roles": ["rubric"]}, {}],
                         ids=["failed", "timeout", "no_report"])
def test_build_draft_gateway_failure_creates_nothing_and_logs_error(env, caplog, fake_kwargs):
    from app.services.gateway import FakeAgentGateway

    with caplog.at_level(logging.ERROR):
        result = run_build(env, FakeAgentGateway(env.data_dir, **fake_kwargs))
    assert isinstance(result, str) and result
    assert env.versions() == []
    errors = [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert errors
    assert str(env.tmp) not in result + " ".join(r.getMessage() for r in errors)


def test_build_draft_completed_without_file_is_failure_and_ignores_stale_file(env, caplog):
    from app.services.gateway import FakeAgentGateway, RoleResult

    write_project_draft(env.data_dir, draft_doc())   # файл от прошлого запуска

    class Lazy(FakeAgentGateway):
        async def run_role(self, run):
            return RoleResult(status="completed", hermes_run_id="x")

    with caplog.at_level(logging.ERROR):
        result = run_build(env, Lazy(env.data_dir))
    assert isinstance(result, str)
    assert env.versions() == []
    assert any(r.levelno >= logging.ERROR for r in caplog.records)


@pytest.mark.parametrize("mutate", [
    lambda d: d.update(kind="scores"),
    lambda d: d.update(schema_version="2"),
    lambda d: d.update(criteria=[]),
    lambda d: d.pop("criteria"),
    lambda d: d.update(project_id="OTHER"),
    lambda d: d["criteria"][0].update(weight=0),
    lambda d: d["criteria"][0].update(agent="wizard"),
    lambda d: d["criteria"][0].pop("source_ref"),
    lambda d: d["criteria"][1].update(name="идея"),
    lambda d: d.update(unexpected=1),
], ids=["kind", "schema_version", "empty", "no_criteria", "project_mismatch", "weight0", "role", "no_source_ref",
        "dup_names", "extra_key"])
def test_build_draft_invalid_document_creates_nothing(env, caplog, mutate):
    doc = draft_doc()
    mutate(doc)
    with caplog.at_level(logging.ERROR):
        result = run_build(env, project_file_gateway(env.data_dir, doc))
    assert isinstance(result, str) and result
    assert env.versions() == []
    assert any(r.levelno >= logging.ERROR for r in caplog.records)
    assert str(env.tmp) not in result


@pytest.mark.parametrize("raw", ["", "{not json", "[]", "null", '{"kind": NaN}', "\u0000"])
def test_build_draft_garbage_file_creates_nothing(env, raw):
    result = run_build(env, project_file_gateway(env.data_dir, raw))
    assert isinstance(result, str)
    assert env.versions() == []


def test_build_draft_oversized_file_is_rejected(env):
    doc = draft_doc()
    doc["criteria"][0]["description"] = "я" * (3 * 1024 * 1024)
    result = run_build(env, project_file_gateway(env.data_dir, doc))
    assert isinstance(result, str)
    assert env.versions() == []


def test_build_draft_symlink_out_of_data_dir_is_not_followed(env):
    outside = env.tmp / "outside.json"
    outside.write_text(json.dumps(draft_doc()), encoding="utf-8")
    from app.services.gateway import FakeAgentGateway, RoleResult

    class Linker(FakeAgentGateway):
        async def run_role(self, run):
            target = env.data_dir / "projects" / PID / "rubric-draft.json"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(outside)
            return RoleResult(status="completed", hermes_run_id="x")

    result = run_build(env, Linker(env.data_dir))
    assert isinstance(result, str)
    assert env.versions() == []


def test_build_draft_unknown_project_returns_reason(env):
    result = run_build(env, project_file_gateway(env.data_dir, draft_doc("NOPE"), "NOPE"), pid="NOPE")
    assert isinstance(result, str)
    assert env.versions("NOPE") == []


def test_build_draft_gateway_exception_is_contained(env, caplog):
    from app.services.gateway import FakeAgentGateway

    class Boom(FakeAgentGateway):
        async def run_role(self, run):
            raise RuntimeError("boom " + str(env.tmp))

    with caplog.at_level(logging.ERROR):
        result = run_build(env, Boom(env.data_dir))
    assert isinstance(result, str)
    assert str(env.tmp) not in result
    assert env.versions() == []
