"""T028: приём отчётов агентов (``app.services.reports``). Тесты написаны ДО реализации (RED).

Контракт (задача T028, contracts/agent-run.md §3, agent-report.schema.json):
``ingest_report(session, *, data_dir, project_id, run_task) -> dict``, ``run_task`` = ``{id, run_id, submission_id,
role, rubric_version}``. Читает ``<data_dir>/runs/<run_id>/reports/<role>.json``, ПОВТОРНО проверяет документ схемой и
правилами и пишет ``criterion_score`` / ``flag`` / ``claim`` (commit — дело вызывающего).

- документ ``kind=scores``; его ``run_id``, ``role``, ``submission_id``, ``rubric_version`` совпадают с задачей;
- оценка принимается, если критерий принадлежит рубрике этой версии проекта, ``criterion.agent`` = роль документа,
  ``score`` — число в ``[0, max_score критерия]``, ``scored`` имеет непустой ``evidence``; иначе она ОТКЛОНЯЕТСЯ
  (не пишется), критерий роли без принятой оценки получает ``no_data`` с причиной ``rejected: <код>`` (отклонена
  оценка по нему) или ``agent_failure`` (оценки по нему в отчёте нет);
- нет файла / битый JSON / документ не по схеме (вне отдельных оценок) / несовпадение идентификаторов -> ВСЕ критерии
  роли получают ``no_data`` (``agent_failure``) и один флаг ``agent_failure`` без путей машины;
- идемпотентность: повторный вызов для той же ``run_task`` ничего не дублирует и возвращает прежний итог;
- тексты очищаются от управляющих символов (``\\n`` и ``\\t`` остаются) и обрезаются до 3000 символов;
- возврат: ``{"accepted", "no_data", "flags", "claims", "rejected": [{"criterion_id", "reason"}]}``:
  ``accepted`` — принятые оценки ``scored``, ``no_data`` — записанные строки ``no_data`` (присланные и добавленные).

Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import asyncio
import copy
import json
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
SUB = "SUBM0000000000000000000001"
OTHER_SUB = "SUBM0000000000000000000002"
RUN = "RUN00000000000000000000001"
RUBRIC_V = 1
# критерий -> (роль, max_score)
CRITERIA = {
    "C_IDEA": ("business", 10), "C_CODE_A": ("code", 10), "C_CODE_B": ("code", 5), "C_DESIGN": ("design", 10),
    "C_UNIQ": ("critic-uniqueness", 10), "C_HONEST": ("critic-honesty", 10), "C_HUMAN": ("human", 10),
}


# ─────────────────────────────── хелперы ───────────────────────────────

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

        self.tmp = tmp_path
        self.data_dir = tmp_path / "data"
        self.data_dir.mkdir()
        self.engine = make_engine(migrated_url(tmp_path))
        self.factory = make_session_factory(self.engine)
        self._task_counter = 0
        self._seed()

    def sql(self, statement: str, **params) -> None:
        with self.engine.begin() as conn:
            conn.execute(sa.text(statement), params)

    def rows(self, statement: str, **params) -> list[dict]:
        with self.engine.connect() as conn:
            return [dict(r) for r in conn.execute(sa.text(statement), params).mappings()]

    def _seed(self) -> None:
        for pid in (PID, OTHER_PID):
            self.sql(
                "INSERT INTO project (id, name, type, status, agents, required_materials, retention_days, "
                "last_activity_at, version, created_at, updated_at) "
                "VALUES (:id, 'Demo', 'other', 'evaluating', '[]', '{}', 7, :ts, 1, :ts, :ts)", id=pid, ts=TS)
        for sid, pid in ((SUB, PID), (OTHER_SUB, OTHER_PID)):
            self.sql(
                "INSERT INTO submission (id, project_id, team_name, intake_status, version, created_at) "
                "VALUES (:id, :p, :id, 'ready', 1, :ts)", id=sid, p=pid, ts=TS)
        self.sql("INSERT INTO run (id, project_id, rubric_version, status, created_at) "
                 "VALUES (:id, :p, :v, 'running', :ts)", id=RUN, p=PID, v=RUBRIC_V, ts=TS)
        self.sql("INSERT INTO rubric (id, project_id, version, status, weights_were_missing, confirmed_at, created_at) "
                 "VALUES ('RUBRIC_1', :p, :v, 'confirmed', 0, :ts, :ts)", p=PID, v=RUBRIC_V, ts=TS)
        # рубрика версии 2 с критерием, которого нет в версии 1
        self.sql("INSERT INTO rubric (id, project_id, version, status, weights_were_missing, created_at) "
                 "VALUES ('RUBRIC_2', :p, 2, 'draft', 0, :ts)", p=PID, ts=TS)
        self.sql("INSERT INTO criterion (id, rubric_id, position, name, description, weight, max_score, agent) "
                 "VALUES ('C_ONLY_V2', 'RUBRIC_2', 0, 'Только v2', '', 1, 10, 'code')")
        # критерий чужого проекта
        self.sql("INSERT INTO rubric (id, project_id, version, status, weights_were_missing, confirmed_at, created_at) "
                 "VALUES ('RUBRIC_X', :p, 1, 'confirmed', 0, :ts, :ts)", p=OTHER_PID, ts=TS)
        self.sql("INSERT INTO criterion (id, rubric_id, position, name, description, weight, max_score, agent) "
                 "VALUES ('C_FOREIGN', 'RUBRIC_X', 0, 'Чужой', '', 1, 10, 'code')")
        for position, (cid, (agent, max_score)) in enumerate(CRITERIA.items()):
            self.sql("INSERT INTO criterion (id, rubric_id, position, name, description, weight, max_score, agent) "
                     "VALUES (:id, 'RUBRIC_1', :pos, :id, '', 1, :max, :agent)",
                     id=cid, pos=position, max=max_score, agent=agent)

    def task(self, role: str = "code", **over) -> dict:
        """Создаёт строку run_task и возвращает словарь, который оркестратор передаёт в ingest_report."""
        self._task_counter += 1
        task_id = f"TASK{self._task_counter:022d}"
        self.sql("INSERT INTO run_task (id, run_id, submission_id, role, state, attempt) "
                 "VALUES (:id, :run, :sub, :role, 'done', 1)", id=task_id, run=RUN, sub=SUB, role=role)
        task = {"id": task_id, "run_id": RUN, "submission_id": SUB, "role": role, "rubric_version": RUBRIC_V}
        task.update(over)
        return task

    def ingest(self, task: dict, project_id: str = PID) -> dict:
        from app.services.reports import ingest_report

        with self.factory() as session:
            result = ingest_report(session, data_dir=self.data_dir, project_id=project_id, run_task=task)
            session.commit()
        return result

    def scores(self, task: dict) -> dict[str, dict]:
        rows = self.rows("SELECT * FROM criterion_score WHERE run_task_id = :t", t=task["id"])
        return {r["criterion_id"]: r for r in rows}

    def flags(self, task: dict) -> list[dict]:
        return self.rows("SELECT * FROM flag WHERE run_task_id = :t ORDER BY id", t=task["id"])

    def claims(self, task: dict) -> list[dict]:
        return self.rows("SELECT * FROM claim WHERE run_task_id = :t ORDER BY id", t=task["id"])

    def counts(self) -> tuple[int, int, int]:
        return tuple(self.rows(f"SELECT count(*) AS n FROM {t}")[0]["n"] for t in ("criterion_score", "flag", "claim"))


@pytest.fixture
def env(tmp_path):
    return Env(tmp_path)


def evidence(ref: str = "api/routes.py:40-88", quote: str | None = "def create()") -> list[dict]:
    item = {"kind": "file", "ref": ref}
    if quote is not None:
        item["quote"] = quote
    return [item]


def score(cid: str, value=7, **over) -> dict:
    data = {
        "criterion_id": cid, "status": "scored", "score": value, "max_score": CRITERIA.get(cid, (None, 10))[1],
        "justification": "Есть тесты и разделение слоёв.", "evidence": evidence(), "confidence": 0.8,
    }
    data.update(over)
    return data


def no_data(cid: str, reason: str = "Материалов нет", **over) -> dict:
    data = {"criterion_id": cid, "status": "no_data", "justification": "Нечего оценивать.", "confidence": 0.5,
            "no_data_reason": reason}
    data.update(over)
    return data


def flag(**over) -> dict:
    data = {"type": "plagiarism", "confidence": 0.7, "note": "Похоже на известный проект.", "evidence": evidence()}
    data.update(over)
    return data


def claim(claim_id: str = "cl-1", **over) -> dict:
    data = {"claim_id": claim_id, "text": "Есть авторизация", "source_ref": {"kind": "slide", "ref": "deck.pdf#4"},
            "verdict": "confirmed", "evidence": evidence()}
    data.update(over)
    return data


def doc(task: dict, scores=None, flags=None, claims=None, **over) -> dict:
    data = {
        "schema_version": "1", "kind": "scores", "run_id": task["run_id"], "submission_id": task["submission_id"],
        "role": task["role"], "rubric_version": task["rubric_version"],
        "scores": scores if scores is not None else [], "flags": flags or [],
    }
    if claims is not None:
        data["claims"] = claims
    data.update(over)
    return data


def write_report(env: Env, task: dict, document, *, name: str | None = None) -> Path:
    target = env.data_dir / "runs" / task["run_id"] / "reports" / f"{name or task['role']}.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(document if isinstance(document, str) else json.dumps(document), encoding="utf-8")
    return target


def code_task_with(env: Env, scores, flags=None, **doc_over) -> tuple[dict, dict]:
    task = env.task("code")
    write_report(env, task, doc(task, scores, flags, **doc_over))
    return task, env.ingest(task)


def assert_agent_failure(env: Env, task: dict, result: dict, role_criteria: tuple[str, ...]) -> None:
    rows = env.scores(task)
    assert set(rows) == set(role_criteria)
    assert all(r["status"] == "no_data" and r["no_data_reason"] == "agent_failure" for r in rows.values())
    assert all(r["score"] is None for r in rows.values())
    flags = env.flags(task)
    assert [f["type"] for f in flags] == ["agent_failure"]
    assert flags[0]["submission_id"] == task["submission_id"] and flags[0]["note"]
    assert str(env.tmp) not in flags[0]["note"] and str(env.data_dir) not in flags[0]["note"]
    assert result["accepted"] == 0 and result["no_data"] == len(role_criteria) and result["flags"] == 1
    assert result["claims"] == 0


# ─────────────────────────────── успешный приём ───────────────────────────────

def test_ingest_writes_scores_with_all_fields(env):
    task, result = code_task_with(env, [score("C_CODE_A", 7), score("C_CODE_B", 4.5)])
    assert result == {"accepted": 2, "no_data": 0, "flags": 0, "claims": 0, "rejected": []}
    rows = env.scores(task)
    assert set(rows) == {"C_CODE_A", "C_CODE_B"}
    a = rows["C_CODE_A"]
    assert len(a["id"]) == 26 and a["run_task_id"] == task["id"] and a["submission_id"] == SUB
    assert a["rubric_version"] == RUBRIC_V and a["status"] == "scored" and a["score"] == 7
    assert a["max_score"] == 10 and a["confidence"] == 0.8 and a["no_data_reason"] is None
    assert a["justification"] == "Есть тесты и разделение слоёв." and a["version"] == 1 and a["created_at"]
    assert json.loads(a["evidence"]) == evidence()
    assert rows["C_CODE_B"]["score"] == 4.5 and rows["C_CODE_B"]["max_score"] == 5


def test_ingest_boundary_scores_are_accepted(env):
    task, result = code_task_with(env, [score("C_CODE_A", 0), score("C_CODE_B", 5)])
    assert result["accepted"] == 2 and result["rejected"] == []
    assert env.scores(task)["C_CODE_A"]["score"] == 0


def test_ingest_works_with_fake_gateway_report(env):
    from app.services.gateway import FakeAgentGateway, RoleRun

    template = doc({"run_id": "X", "submission_id": "X", "role": "code", "rubric_version": 1},
                   [score("C_CODE_A", 8), score("C_CODE_B", 3)])
    gateway = FakeAgentGateway(env.data_dir, {"code": template})
    task = env.task("code")
    run = RoleRun(run_id=task["run_id"], role="code", submission_id=SUB, workdir="projects/p/submissions/s",
                  rubric_version=RUBRIC_V, instructions="-", input="-")
    assert asyncio.run(gateway.run_role(run)).status == "completed"
    result = env.ingest(task)
    assert result["accepted"] == 2 and result["rejected"] == []


def test_ingest_agent_reported_no_data_is_stored(env):
    task, result = code_task_with(env, [score("C_CODE_A", 6), no_data("C_CODE_B", "Нет материалов")])
    assert result["accepted"] == 1 and result["no_data"] == 1 and result["rejected"] == []
    row = env.scores(task)["C_CODE_B"]
    assert row["status"] == "no_data" and row["score"] is None and row["no_data_reason"] == "Нет материалов"


def test_last_duplicate_score_wins(env):
    task, result = code_task_with(env, [score("C_CODE_A", 3), score("C_CODE_A", 9), score("C_CODE_B", 2)])
    assert result["accepted"] == 2
    assert env.scores(task)["C_CODE_A"]["score"] == 9
    assert env.counts()[0] == 2


# ─────────────────────────────── отклонение отдельных оценок ───────────────────────────────

@pytest.mark.parametrize("bad, reason", [
    (score("C_CODE_A", 11), "score_out_of_range"),
    (score("C_CODE_A", -1), "score_out_of_range"),
    (score("C_CODE_B", 5.01), "score_out_of_range"),
    (score("C_CODE_A", evidence=[]), "no_evidence"),
    (score("C_CODE_A", evidence=None), "no_evidence"),
    (score("C_CODE_A", max_score=20), "max_score_mismatch"),
], ids=["above", "negative", "above_crit_max", "evidence_empty", "evidence_null", "max_mismatch"])
def test_bad_score_is_rejected_and_criterion_becomes_no_data(env, bad, reason):
    if bad["evidence"] is None:
        bad = {k: v for k, v in bad.items() if k != "evidence"}
    cid = bad["criterion_id"]
    other = score("C_CODE_B" if cid == "C_CODE_A" else "C_CODE_A", 4)
    task, result = code_task_with(env, [bad, other])
    rows = env.scores(task)
    assert rows[cid]["status"] == "no_data" and rows[cid]["score"] is None
    assert rows[cid]["no_data_reason"] == f"rejected: {reason}"
    kept = "C_CODE_B" if cid == "C_CODE_A" else "C_CODE_A"
    assert rows[kept]["status"] == "scored"
    assert result["rejected"] == [{"criterion_id": cid, "reason": reason}]
    assert result["no_data"] >= 1 and result["flags"] == 0
    assert not [r for r in rows.values() if r["status"] == "scored" and r["criterion_id"] == cid]


def test_infinite_score_literal_is_out_of_range_not_a_crash(env):
    task = env.task("code")
    raw = json.dumps(doc(task, [score("C_CODE_A", "__INF__"), score("C_CODE_B", 3)])).replace('"__INF__"', "1e999")
    write_report(env, task, raw)
    result = env.ingest(task)
    assert result["rejected"] == [{"criterion_id": "C_CODE_A", "reason": "score_out_of_range"}]
    assert env.scores(task)["C_CODE_A"]["status"] == "no_data"


def test_scored_without_evidence_never_lands_as_scored(env):
    task, result = code_task_with(env, [score("C_CODE_A", 9, evidence=[]), score("C_CODE_B", 4)])
    rows = env.scores(task)
    assert rows["C_CODE_A"]["status"] == "no_data" and rows["C_CODE_B"]["status"] == "scored"
    assert result["accepted"] == 1 and result["no_data"] == 1
    assert env.flags(task) == []   # это отклонение оценки, а не сбой всего отчёта


def test_blank_evidence_ref_does_not_count_as_evidence(env):
    bad = score("C_CODE_A", 9, evidence=[{"kind": "file", "ref": "   "}])
    task, result = code_task_with(env, [bad, score("C_CODE_B", 4)])
    assert env.scores(task)["C_CODE_A"]["status"] == "no_data"
    assert result["rejected"][0]["reason"] == "no_evidence"


def test_criterion_not_in_rubric_is_rejected_without_row(env):
    task, result = code_task_with(env, [score("C_NOPE", 5), score("C_CODE_A", 6), score("C_CODE_B", 3)])
    assert result["rejected"] == [{"criterion_id": "C_NOPE", "reason": "criterion_not_in_rubric"}]
    assert set(env.scores(task)) == {"C_CODE_A", "C_CODE_B"}


@pytest.mark.parametrize("cid", ["C_ONLY_V2", "C_FOREIGN"], ids=["other_version", "other_project"])
def test_criterion_of_other_rubric_version_or_project_is_rejected(env, cid):
    task, result = code_task_with(env, [score(cid, 5), score("C_CODE_A", 6), score("C_CODE_B", 3)])
    assert result["rejected"] == [{"criterion_id": cid, "reason": "criterion_not_in_rubric"}]
    assert cid not in env.scores(task)


@pytest.mark.parametrize("cid", ["C_DESIGN", "C_IDEA", "C_HUMAN"])
def test_role_cannot_score_criterion_of_another_role(env, cid):
    task, result = code_task_with(env, [score(cid, 5), score("C_CODE_A", 6), score("C_CODE_B", 3)])
    assert result["rejected"] == [{"criterion_id": cid, "reason": "role_not_allowed"}]
    assert cid not in env.scores(task)   # критерий чужой роли этой задачей не трогается
    assert result["accepted"] == 2


def test_role_criterion_missing_from_report_becomes_agent_failure_no_data(env):
    task, result = code_task_with(env, [score("C_CODE_A", 6)])
    rows = env.scores(task)
    assert rows["C_CODE_B"]["status"] == "no_data" and rows["C_CODE_B"]["no_data_reason"] == "agent_failure"
    assert result["accepted"] == 1 and result["no_data"] == 1 and result["rejected"] == []


def test_every_criterion_of_the_role_gets_exactly_one_row(env):
    task, result = code_task_with(env, [score("C_CODE_A", 99), score("C_NOPE", 1), score("C_DESIGN", 2)])
    rows = env.scores(task)
    assert set(rows) == {"C_CODE_A", "C_CODE_B"}
    assert all(r["status"] == "no_data" for r in rows.values())
    assert env.counts()[0] == 2
    assert result["accepted"] == 0 and result["no_data"] == 2 and len(result["rejected"]) == 3


def test_schema_invalid_score_item_is_rejected_not_whole_report(env):
    bad = score("C_CODE_A", 5, confidence=7)
    task, result = code_task_with(env, [bad, score("C_CODE_B", 3)])
    assert result["rejected"] == [{"criterion_id": "C_CODE_A", "reason": "schema_invalid"}]
    assert env.scores(task)["C_CODE_B"]["status"] == "scored"
    assert env.flags(task) == []


# ─────────────────────────────── сбой отчёта целиком ───────────────────────────────

def test_missing_file_gives_agent_failure_for_all_role_criteria(env):
    task = env.task("code")
    result = env.ingest(task)
    assert_agent_failure(env, task, result, ("C_CODE_A", "C_CODE_B"))
    assert result["rejected"] == []


def test_failure_only_touches_criteria_of_the_role(env):
    task = env.task("design")
    result = env.ingest(task)
    assert_agent_failure(env, task, result, ("C_DESIGN",))


def test_role_without_criteria_gets_flag_but_no_rows(env):
    task = env.task("code")
    env.sql("DELETE FROM criterion WHERE agent = 'code'")
    result = env.ingest(task)
    assert env.scores(task) == {}
    assert result["no_data"] == 0 and result["flags"] == 1


@pytest.mark.parametrize("raw", ["", "{broken", "[]", "null", '{"scores": NaN}', "﻿{}", "\u0000"],
                         ids=["empty", "broken", "array", "null", "nan", "bom", "nul"])
def test_unparseable_report_gives_agent_failure(env, raw):
    task = env.task("code")
    write_report(env, task, raw)
    result = env.ingest(task)
    assert_agent_failure(env, task, result, ("C_CODE_A", "C_CODE_B"))


def test_non_utf8_report_gives_agent_failure(env):
    task = env.task("code")
    target = write_report(env, task, "{}")
    target.write_bytes(b'{"x": "\xff\xfe"}')
    assert_agent_failure(env, task, env.ingest(task), ("C_CODE_A", "C_CODE_B"))


def make_invalid(mutator):
    def build(task):
        document = doc(task, [score("C_CODE_A", 5), score("C_CODE_B", 3)])
        mutator(document)
        return document
    return build


@pytest.mark.parametrize("build", [
    make_invalid(lambda d: d.pop("flags")),
    make_invalid(lambda d: d.pop("scores")),
    make_invalid(lambda d: d.update(scores="oops")),
    make_invalid(lambda d: d.update(schema_version="2")),
    make_invalid(lambda d: d.update(kind="rubric_draft")),
    make_invalid(lambda d: d.update(unexpected=1)),
    make_invalid(lambda d: d.update(flags=[{"type": "bogus", "confidence": 1, "note": "n", "evidence": evidence()}])),
    make_invalid(lambda d: d.update(rubric_version=0)),
    make_invalid(lambda d: d.update(role="rubric")),
    make_invalid(lambda d: d.update(run_id="OTHER-RUN")),
    make_invalid(lambda d: d.update(submission_id=OTHER_SUB)),
    make_invalid(lambda d: d.update(role="design")),
    make_invalid(lambda d: d.update(rubric_version=2)),
], ids=["no_flags", "no_scores", "scores_not_array", "schema_version", "kind", "extra_key", "bad_flag_type",
        "version_zero", "role_rubric", "run_id_mismatch", "submission_mismatch", "role_mismatch",
        "version_mismatch"])
def test_invalid_or_mismatching_document_gives_agent_failure(env, build):
    task = env.task("code")
    write_report(env, task, build(task))
    result = env.ingest(task)
    assert_agent_failure(env, task, result, ("C_CODE_A", "C_CODE_B"))
    assert env.counts()[2] == 0


def test_flags_from_invalid_document_are_not_written(env):
    task = env.task("code")
    bad = doc(task, [score("C_CODE_A", 5)], [flag(type="plagiarism")], unexpected=1)
    write_report(env, task, bad)
    env.ingest(task)
    assert [f["type"] for f in env.flags(task)] == ["agent_failure"]


def test_report_outside_reports_dir_is_not_read_for_hostile_run_id(env):
    task = env.task("code", run_id="../outside")
    outside = env.data_dir / "outside" / "reports"
    outside.mkdir(parents=True)
    (outside / "code.json").write_text(json.dumps(doc(task, [score("C_CODE_A", 5)])), encoding="utf-8")
    result = env.ingest(task)
    assert result["accepted"] == 0 and result["flags"] == 1


def test_symlinked_report_is_not_followed(env):
    task = env.task("code")
    secret = env.tmp / "elsewhere.json"
    secret.write_text(json.dumps(doc(task, [score("C_CODE_A", 5), score("C_CODE_B", 5)])), encoding="utf-8")
    target = env.data_dir / "runs" / task["run_id"] / "reports" / "code.json"
    target.parent.mkdir(parents=True)
    target.symlink_to(secret)
    assert_agent_failure(env, task, env.ingest(task), ("C_CODE_A", "C_CODE_B"))


def test_oversized_report_gives_agent_failure(env):
    task = env.task("code")
    big = doc(task, [score("C_CODE_A", 5)], summary="я" * (3 * 1024 * 1024))
    write_report(env, task, big)
    assert_agent_failure(env, task, env.ingest(task), ("C_CODE_A", "C_CODE_B"))


# ─────────────────────────────── флаги ───────────────────────────────

def test_flags_are_written_with_task_and_criterion(env):
    f = flag(type="claim_mismatch", criterion_id="C_CODE_A", confidence=0.6, note="Расхождение", evidence=evidence())
    task, result = code_task_with(env, [score("C_CODE_A", 5), score("C_CODE_B", 5)], [f])
    assert result["flags"] == 1
    (row,) = env.flags(task)
    assert len(row["id"]) == 26 and row["run_task_id"] == task["id"] and row["submission_id"] == SUB
    assert row["type"] == "claim_mismatch" and row["criterion_id"] == "C_CODE_A" and row["confidence"] == 0.6
    assert row["note"] == "Расхождение" and json.loads(row["evidence"]) == evidence() and row["created_at"]


def test_flag_without_criterion_has_null_criterion(env):
    task, _ = code_task_with(env, [score("C_CODE_A", 5), score("C_CODE_B", 5)], [flag()])
    assert env.flags(task)[0]["criterion_id"] is None


def test_flag_with_unknown_criterion_keeps_flag_but_drops_the_reference(env):
    task, result = code_task_with(env, [score("C_CODE_A", 5), score("C_CODE_B", 5)],
                                  [flag(criterion_id="C_NOPE")])
    assert result["flags"] == 1
    assert env.flags(task)[0]["criterion_id"] is None


def test_flag_related_submission_must_belong_to_the_project(env):
    flags = [flag(related_submission_id=OTHER_SUB), flag(related_submission_id="SUBM-NOPE"),
             flag(related_submission_id=SUB, related_url="https://example.org/repo")]
    task, result = code_task_with(env, [score("C_CODE_A", 5), score("C_CODE_B", 5)], flags)
    rows = env.flags(task)
    assert result["flags"] == 3
    related = sorted(str(r["related_submission_id"]) for r in rows)
    assert related == sorted(["None", "None", SUB])
    assert [r["related_url"] for r in rows if r["related_submission_id"] == SUB] == ["https://example.org/repo"]


@pytest.mark.parametrize("url", ["javascript:alert(1)", "data:text/html,x", "file:///etc/passwd", "ftp://x/y"])
def test_flag_related_url_accepts_only_http_and_https(env, url):
    task, _ = code_task_with(env, [score("C_CODE_A", 5), score("C_CODE_B", 5)], [flag(related_url=url)])
    assert env.flags(task)[0]["related_url"] is None


# ─────────────────────────────── утверждения ───────────────────────────────

def test_honesty_claims_are_written(env):
    task = env.task("critic-honesty")
    write_report(env, task, doc(task, [score("C_HONEST", 6)], claims=[claim("cl-1"), claim("cl-2", verdict="contradicted")]))
    result = env.ingest(task)
    assert result["claims"] == 2 and result["accepted"] == 1
    rows = env.claims(task)
    assert {r["claim_id"] for r in rows} == {"cl-1", "cl-2"}
    first = next(r for r in rows if r["claim_id"] == "cl-1")
    assert len(first["id"]) == 26 and first["run_task_id"] == task["id"] and first["text"] == "Есть авторизация"
    assert first["verdict"] == "confirmed"
    assert json.loads(first["source_ref"]) == {"kind": "slide", "ref": "deck.pdf#4"}
    assert json.loads(first["evidence"]) == evidence()


def test_claims_from_other_roles_are_ignored(env):
    task = env.task("code")
    write_report(env, task, doc(task, [score("C_CODE_A", 5), score("C_CODE_B", 5)], claims=[claim()]))
    result = env.ingest(task)
    assert result["claims"] == 0 and env.claims(task) == []


def test_duplicate_claim_ids_last_wins(env):
    task = env.task("critic-honesty")
    write_report(env, task, doc(task, [score("C_HONEST", 6)],
                                claims=[claim("cl-1", verdict="confirmed"), claim("cl-1", verdict="not_found")]))
    assert env.ingest(task)["claims"] == 1
    assert [r["verdict"] for r in env.claims(task)] == ["not_found"]


# ─────────────────────────────── очистка текстов ───────────────────────────────

def test_texts_are_stripped_of_control_characters(env):
    dirty = "ок\x00\x07\x1b[31mкрасный\x1b[0m‮текст‏﻿\ud800 конец\r\nстрока\tтаб\x7f"
    f = flag(note=dirty)
    task, _ = code_task_with(env, [score("C_CODE_A", 5, justification=dirty), score("C_CODE_B", 5)], [f])
    for text in (env.scores(task)["C_CODE_A"]["justification"], env.flags(task)[0]["note"]):
        assert all(ch in "\n\t" or (ch.isprintable() and ch not in "‮‏﻿") for ch in text), repr(text)
        assert "ок" in text and "конец" in text and "\nстрока\tтаб" in text
        assert "\r" not in text and "\x1b" not in text


def test_texts_in_evidence_claims_and_reasons_are_cleaned(env):
    ev = [{"kind": "file", "ref": "a.py:1\x00", "quote": "q\x1b[0m"}]
    task = env.task("critic-honesty")
    write_report(env, task, doc(task, [no_data("C_HONEST", "нет\x00данных")],
                                claims=[claim(text="утв\x07ерждение", evidence=ev)]))
    env.ingest(task)
    row = env.scores(task)["C_HONEST"]
    assert row["no_data_reason"] == "нетданных"
    assert json.loads(env.claims(task)[0]["evidence"]) == [{"kind": "file", "ref": "a.py:1", "quote": "q[0m"}]
    assert env.claims(task)[0]["text"] == "утверждение"


def test_long_text_is_kept_within_3000_characters(env):
    long_text = "я" * 3000
    task, _ = code_task_with(env, [score("C_CODE_A", 5, justification=long_text), score("C_CODE_B", 5)])
    stored = env.scores(task)["C_CODE_A"]["justification"]
    assert len(stored) == 3000


def test_whitespace_only_justification_of_scored_item_is_rejected(env):
    task, result = code_task_with(env, [score("C_CODE_A", 5, justification="  \x00\x07  "), score("C_CODE_B", 5)])
    assert result["rejected"] == [{"criterion_id": "C_CODE_A", "reason": "empty_justification"}]
    assert env.scores(task)["C_CODE_A"]["status"] == "no_data"


# ─────────────────────────────── идемпотентность и ввод ───────────────────────────────

def test_second_call_does_not_duplicate_and_returns_same_summary(env):
    task = env.task("code")
    write_report(env, task, doc(task, [score("C_CODE_A", 99), score("C_CODE_B", 3)], [flag()]))
    first = env.ingest(task)
    counts = env.counts()
    second = env.ingest(task)
    assert second == first
    assert env.counts() == counts
    assert first["accepted"] == 1 and first["flags"] == 1 and first["rejected"][0]["reason"] == "score_out_of_range"


def test_second_call_after_failure_does_not_duplicate_flag(env):
    task = env.task("code")
    first = env.ingest(task)
    counts = env.counts()
    assert env.ingest(task) == first
    assert env.counts() == counts == (2, 1, 0)


def test_second_call_ignores_a_report_that_changed_meanwhile(env):
    task = env.task("code")
    write_report(env, task, doc(task, [score("C_CODE_A", 5), score("C_CODE_B", 3)]))
    first = env.ingest(task)
    write_report(env, task, doc(task, [score("C_CODE_A", 9), score("C_CODE_B", 9)]))
    assert env.ingest(task) == first
    assert env.scores(task)["C_CODE_A"]["score"] == 5


def test_other_task_of_the_same_role_ingests_independently(env):
    first_task = env.task("code")
    write_report(env, first_task, doc(first_task, [score("C_CODE_A", 5), score("C_CODE_B", 3)]))
    env.ingest(first_task)
    second_task = env.task("code")
    write_report(env, second_task, doc(second_task, [score("C_CODE_A", 8), score("C_CODE_B", 4)]))
    assert env.ingest(second_task)["accepted"] == 2
    assert env.counts()[0] == 4   # старые записи остаются (FR-024)


def test_unknown_run_task_or_foreign_project_raises(env):
    task = env.task("code")
    with pytest.raises(LookupError):
        env.ingest(dict(task, id="TASK-NOPE"))
    with pytest.raises(LookupError):
        env.ingest(task, project_id=OTHER_PID)
    assert env.counts() == (0, 0, 0)


def test_run_task_without_submission_is_rejected_as_programming_error(env):
    task = env.task("code")
    with pytest.raises(ValueError):
        env.ingest(dict(task, submission_id=None))


def test_ingest_does_not_commit_by_itself(env):
    from app.services.reports import ingest_report

    task = env.task("code")
    write_report(env, task, doc(task, [score("C_CODE_A", 5), score("C_CODE_B", 3)]))
    with env.factory() as session:
        ingest_report(session, data_dir=env.data_dir, project_id=PID, run_task=task)
        session.rollback()
    assert env.counts() == (0, 0, 0)


def test_all_critic_roles_have_their_criteria_scored(env):
    for role, cid in (("business", "C_IDEA"), ("design", "C_DESIGN"), ("critic-uniqueness", "C_UNIQ"),
                      ("critic-honesty", "C_HONEST")):
        task = env.task(role)
        write_report(env, task, doc(task, [score(cid, 4)]))
        result = env.ingest(task)
        assert result["accepted"] == 1 and result["rejected"] == [], role


def test_document_is_not_mutated_by_ingest_inputs(env):
    task = env.task("code")
    original = copy.deepcopy(task)
    write_report(env, task, doc(task, [score("C_CODE_A", 5), score("C_CODE_B", 3)]))
    env.ingest(task)
    assert task == original
