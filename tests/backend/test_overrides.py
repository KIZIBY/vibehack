"""T034: ручная правка балла ``PUT /api/v1/submissions/{id}/criteria/{criterion_id}/override`` (FR-027).
Тесты написаны ДО реализации (RED).

Контракт (openapi.yaml: overrideScore, Explanation):
- тело ``{score, reason, expected_version}``; ``score`` — число в ``[0, max_score]`` (NaN, inf, bool, строки -> 422),
  ``reason`` 3–1000 символов после обрезки и очистки управляющих символов, ``expected_version`` — целое >= 0;
- правка относится к ТЕКУЩЕЙ записи ``criterion_score`` критерия; ``expected_version`` обязан равняться числу уже
  существующих правок этой записи, иначе 409 ``version_conflict``; проверка и вставка — один оператор (без гонки);
- нет записи оценки (в том числе ``human_pending``) -> 409 ``conflict`` «нет оценки для правки»; нет работы/критерия -> 404;
- вставляется строка ``score_override`` (actor — имя пользователя сессии), исходная оценка агента не меняется,
  обновляется ``project.last_activity_at``, публикуется событие ``score.changed`` {submission_id, criterion_id};
  запись в ``journal_event`` НЕ делается; ответ — обновлённое ``Explanation``.

Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import asyncio
import threading

import pytest
from test_results import (  # noqa: F401  (хелперы и данные T034)
    BASE, C_BIZ, C_CODE, C_HUMAN, CRITERIA_V1, PID, RUN1, S1, S2, T1, T2, TS, Env, assert_valid, board, explain,
    row_of, seed_basic,
)


@pytest.fixture
def env(tmp_path):
    e = Env(tmp_path)
    e.add_project()
    e.add_rubric(1, CRITERIA_V1)
    e.add_run(RUN1)
    return e


def url(sid=S1, cid=C_CODE) -> str:
    return f"/api/v1/submissions/{sid}/criteria/{cid}/override"


def body(score=9.0, reason="жюри не согласно с агентом", expected_version=0) -> dict:
    return {"score": score, "reason": reason, "expected_version": expected_version}


def put(env, payload=None, *, sid=S1, cid=C_CODE, client=None, raw: str | None = None):
    client = client or env.client()
    if raw is not None:
        return client.put(url(sid, cid), content=raw, headers={"content-type": "application/json"})
    return client.put(url(sid, cid), json=body() if payload is None else payload)


def overrides(env) -> list[dict]:
    return env.rows("SELECT * FROM score_override ORDER BY created_at, id")


def code_record(env) -> str:
    return env.rows("SELECT id FROM criterion_score WHERE submission_id = :s AND criterion_id = :c", s=S1, c=C_CODE)[0]["id"]


def events(env, last: int = 0) -> list:
    from app.routers.events import get_event_bus

    subscription = get_event_bus(env.app).subscribe(PID, last_event_id=last)

    async def collect():
        found = []
        while True:
            try:
                found.append(await asyncio.wait_for(subscription.__anext__(), 0.15))
            except (asyncio.TimeoutError, StopAsyncIteration):
                await subscription.aclose()
                return found

    return asyncio.run(collect())


@pytest.fixture
def seeded(env):
    seed_basic(env)
    return env


# ─────────────────────────────── успешная правка ───────────────────────────────

def test_override_requires_session(seeded):
    resp = put(seeded, client=seeded.client(auth=False))
    assert resp.status_code == 401
    assert overrides(seeded) == []


def test_override_happy_path_returns_explanation_and_inserts_row(seeded):
    resp = put(seeded, body(9.0, "  жюри не согласно с агентом  "))
    assert resp.status_code == 200, resp.text
    payload = resp.json()
    assert_valid("Explanation", payload)
    assert payload["score"] == 9.0 and payload["agent_score"] == 8.0 and payload["status"] == "scored"
    assert payload["version"] == 1
    assert payload["override"]["score"] == 9.0 and payload["override"]["reason"] == "жюри не согласно с агентом"
    rows = overrides(seeded)
    assert len(rows) == 1
    row = rows[0]
    assert row["criterion_score_id"] == code_record(seeded)
    assert row["submission_id"] == S1 and row["score"] == 9.0
    assert row["actor"] == "demo" and row["reason"] == "жюри не согласно с агентом"
    assert len(row["id"]) == 26 and row["created_at"]
    # повторное чтение даёт то же
    assert explain(seeded, S1, C_CODE)["override"]["score"] == 9.0


def test_override_does_not_change_agent_record_and_writes_no_journal(seeded):
    before = seeded.rows("SELECT * FROM criterion_score ORDER BY id")
    assert put(seeded).status_code == 200
    assert seeded.rows("SELECT * FROM criterion_score ORDER BY id") == before
    assert seeded.rows("SELECT COUNT(*) AS n FROM journal_event")[0]["n"] == 0


def test_override_actor_is_session_user(seeded):
    resp = put(seeded, client=seeded.client(user="alice"))
    assert resp.status_code == 200
    assert overrides(seeded)[0]["actor"] == "alice"


def test_override_reflected_in_leaderboard(seeded):
    from app.scoring import compute_score

    before = row_of(board(seeded), S2)
    assert put(seeded, body(10.0)).status_code == 200
    after = board(seeded)
    row = row_of(after, S1)
    assert row["cells"][C_CODE]["score"] == 10.0 and row["cells"][C_CODE]["overridden"] is True
    assert row["total"] == compute_score([
        {"name": C_CODE, "score": 10.0, "max_score": 10.0, "weight": 2.0},
        {"name": C_BIZ, "score": 4.0, "max_score": 5.0, "weight": 1.0}])["total"]
    assert row_of(after, S2)["total"] == before["total"]


def test_override_touches_project_activity(seeded):
    assert put(seeded).status_code == 200
    activity = seeded.rows("SELECT last_activity_at FROM project WHERE id = :p", p=PID)[0]["last_activity_at"]
    assert str(activity) != TS


def test_override_publishes_score_changed_once(seeded):
    assert put(seeded).status_code == 200
    found = events(seeded)
    assert [(e.type, e.data) for e in found] == [("score.changed", {"submission_id": S1, "criterion_id": C_CODE})]


def test_no_event_when_override_rejected(seeded):
    assert put(seeded, body(9.0, expected_version=5)).status_code == 409
    assert put(seeded, body(99.0)).status_code == 422
    assert events(seeded) == []


def test_override_boundaries_zero_and_max_are_allowed(seeded):
    assert put(seeded, body(0, expected_version=0)).status_code == 200
    resp = put(seeded, body(10, expected_version=1))
    assert resp.status_code == 200 and resp.json()["score"] == 10.0 and resp.json()["version"] == 2


def test_reason_exactly_1000_after_trim_is_allowed(seeded):
    resp = put(seeded, body(5.0, " " + "я" * 1000 + " "))
    assert resp.status_code == 200
    assert overrides(seeded)[0]["reason"] == "я" * 1000


def test_reason_control_characters_are_removed(seeded):
    resp = put(seeded, body(5.0, "при\x00чи\x07на‮"))
    assert resp.status_code == 200
    assert overrides(seeded)[0]["reason"] == "причина"


def test_override_targets_current_record_after_rerun(seeded):
    seeded.add_run("RUN00000000000000000000002", created_at=T2)
    t_new = seeded.add_task("TASK0000000000000000000040", "RUN00000000000000000000002", S1, "code")
    newer = seeded.add_score(t_new, S1, C_CODE, 5.0, created_at=T2)
    assert put(seeded).status_code == 200
    assert overrides(seeded)[0]["criterion_score_id"] == newer


def test_override_on_agent_no_data_record_is_allowed(seeded):
    seeded.add_submission("SUBM0000000000000000000004", "Гамма")
    task = seeded.add_task("TASK0000000000000000000041", RUN1, "SUBM0000000000000000000004", "code", state="no_data")
    seeded.add_score(task, "SUBM0000000000000000000004", C_CODE, None, status="no_data", reason="нет материалов")
    resp = put(seeded, sid="SUBM0000000000000000000004")
    assert resp.status_code == 200
    assert resp.json()["status"] == "scored" and resp.json()["score"] == 9.0 and resp.json()["agent_score"] is None


def test_override_matches_record_of_previous_rubric_version_by_name(seeded):
    new_code = "CRIT00000000000000000000V2"
    seeded.add_rubric(2, [(new_code, "КОД", 2.0, 10.0, "code", "Качество кода")])
    resp = put(seeded, cid=new_code)
    assert resp.status_code == 200, resp.text
    assert resp.json()["criterion_id"] == new_code and resp.json()["score"] == 9.0
    assert overrides(seeded)[0]["criterion_score_id"] == code_record(seeded)


# ─────────────────────────────── версия ───────────────────────────────

def test_expected_version_sequence_and_conflicts(seeded):
    assert put(seeded, body(6.0, expected_version=0)).json()["version"] == 1
    stale = put(seeded, body(7.0, expected_version=0))
    assert stale.status_code == 409 and stale.json()["error"]["code"] == "version_conflict"
    ahead = put(seeded, body(7.0, expected_version=2))
    assert ahead.status_code == 409 and ahead.json()["error"]["code"] == "version_conflict"
    assert len(overrides(seeded)) == 1
    second = put(seeded, body(7.0, expected_version=1))
    assert second.status_code == 200 and second.json()["version"] == 2
    assert [r["score"] for r in overrides(seeded)] == [6.0, 7.0]


def test_concurrent_overrides_with_same_version_exactly_one_wins(seeded):
    barrier = threading.Barrier(2)
    codes: list[int] = []

    def worker(score):
        client = seeded.client()
        barrier.wait()
        codes.append(client.put(url(), json=body(score, expected_version=0)).status_code)

    threads = [threading.Thread(target=worker, args=(score,)) for score in (6.0, 7.0)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(codes) == [200, 409]
    assert len(overrides(seeded)) == 1


# ─────────────────────────────── отказы ───────────────────────────────

def test_override_without_score_record_is_409_conflict(seeded):
    resp = put(seeded, cid=C_HUMAN)
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "conflict"
    assert "нет оценки" in resp.json()["error"]["message"].lower()
    # критерий без записи у другой работы
    resp = put(seeded, sid=S2, cid=C_BIZ)
    assert resp.status_code == 409 and resp.json()["error"]["code"] == "conflict"
    assert overrides(seeded) == []
    assert events(seeded) == []


def test_override_404_cases(seeded):
    assert put(seeded, sid="NOPE0000000000000000000000").status_code == 404
    assert put(seeded, cid="NOPE0000000000000000000000").status_code == 404
    seeded.add_submission("SUBM0000000000000000000005", "Удалённые", deleted=True)
    assert put(seeded, sid="SUBM0000000000000000000005").status_code == 404
    assert overrides(seeded) == []


def test_override_when_rubric_not_confirmed_is_404(tmp_path):
    e = Env(tmp_path)
    e.add_project()
    e.add_rubric(1, [("CRIT0000000000000000000001", "Код", 2.0, 10.0, "code", "")], confirm=False)
    e.add_submission(S1, "Альфа")
    assert put(e, cid="CRIT0000000000000000000001").status_code == 404


@pytest.mark.parametrize("payload", [
    body(-0.5), body(10.5), body(1e308), body(10**400),
    body("5"), body(None), body(True), body([5]),
    body(reason="ab"), body(reason="   "), body(reason="\x00\x01\x02"), body(reason="я" * 1001), body(reason=5),
    body(reason=None),
    body(expected_version=-1), body(expected_version=1.5), body(expected_version="0"), body(expected_version=True),
    body(expected_version=None),
    {"score": 5, "reason": "причина"}, {"score": 5, "expected_version": 0}, {"reason": "причина", "expected_version": 0},
    [], "x",
])
def test_override_invalid_body_is_422(seeded, payload):
    resp = put(seeded, payload)
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "invalid"
    assert overrides(seeded) == []


@pytest.mark.parametrize("raw", [
    '{"score": NaN, "reason": "причина", "expected_version": 0}',
    '{"score": Infinity, "reason": "причина", "expected_version": 0}',
    '{"score": -Infinity, "reason": "причина", "expected_version": 0}',
    "not json",
])
def test_override_nonfinite_or_broken_json_is_422(seeded, raw):
    resp = put(seeded, raw=raw)
    assert resp.status_code == 422, resp.text
    assert overrides(seeded) == []


def test_override_score_checked_against_current_criterion_max(seeded):
    # бизнес: max_score = 5
    assert put(seeded, body(5.5), cid=C_BIZ).status_code == 422
    assert put(seeded, body(5.0), cid=C_BIZ).status_code == 200
