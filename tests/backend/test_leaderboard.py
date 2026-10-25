"""T029 (часть 2): ``app.services.leaderboard`` — чистые функции таблицы оценок и пояснений.
Тесты написаны ДО реализации (RED).

Контракт (модуль определяет dataclass-входы, БД не трогает):
- ``CriterionDef(id, name, weight, max_score, agent)``; ``RubricInfo(version, criteria)``;
- ``EvidenceItem(kind, ref, quote=None, available=True)``; ``OverrideInfo(score, reason, at)``;
- ``CriterionScore(criterion_id, status, agent_score=None, max_score=None, rubric_version=1, justification="",
  evidence=(), confidence=None, no_data_reason=None, override=None, run_id=None, version=1)``;
- ``FlagInfo(type, confidence, note, evidence=(), criterion_id=None, related_submission_id=None, related_url=None)``;
- ``SubmissionScores(submission_id, team_name, scores=(), flags=(), cost_usd=None)``;
- ``build_leaderboard(*, project_id, rubric, submissions, generated_at, changed_criteria=None,
  sort="total", order="desc", flag=None) -> dict`` — схема ``Leaderboard`` из contracts/openapi.yaml;
- ``build_explanation(*, criterion, team_name, entry, flags=(), ) -> dict`` — схема ``Explanation``.

Правила: текущий балл = ``override.score``, иначе ``agent_score``; в итог входят только ``scored``
(``no_data`` и ``human_pending`` не входят); итог — ``compute_score`` (критерии идентифицируются по id);
``complete`` = у каждого критерия рубрики есть значение; ранги: убывание итога, равные — одно место (1,1,3),
без итога — ``rank=None`` внизу; ранг считается по всей таблице до фильтра; ``stale`` — оценка с
``rubric_version`` меньше ``changed_criteria[criterion_id]``.
Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import copy
import json
from datetime import datetime
from pathlib import Path

import jsonschema
import pytest
import yaml
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

REPO = Path(__file__).resolve().parents[2]
OPENAPI = REPO / "specs" / "001-ai-judge-platform" / "contracts" / "openapi.yaml"
NOW = "2026-10-25T12:00:00+00:00"


# ─────────────────────────────── схемы ───────────────────────────────

def schema_validator(name: str) -> jsonschema.Draft202012Validator:
    doc = yaml.safe_load(OPENAPI.read_text(encoding="utf-8"))
    registry = Registry().with_resource("urn:openapi", Resource.from_contents(doc, default_specification=DRAFT202012))
    return jsonschema.Draft202012Validator({"$ref": f"urn:openapi#/components/schemas/{name}"}, registry=registry)


def assert_valid(name: str, payload: dict) -> None:
    schema_validator(name).validate(payload)
    json.dumps(payload, ensure_ascii=False)   # результат сериализуем как есть
    for key in ("generated_at",):
        if key in payload:
            datetime.fromisoformat(payload[key])


# ─────────────────────────────── построители входов ───────────────────────────────

def L():
    import app.services.leaderboard as lb
    return lb


def rubric(version=1, criteria=None):
    lb = L()
    if criteria is None:
        criteria = (
            lb.CriterionDef("c1", "Код", 2, 10, "code"),
            lb.CriterionDef("c2", "Бизнес", 1, 5, "business"),
            lb.CriterionDef("c3", "Дизайн", 1, 10, "design"),
            lb.CriterionDef("c4", "Жюри", 1, 10, "human"),
        )
    return lb.RubricInfo(version=version, criteria=tuple(criteria))


def ev(ref="api/routes.py:1-9", **kw):
    return L().EvidenceItem(kind=kw.pop("kind", "file"), ref=ref, **kw)


def scored(cid, score, *, version=1, override=None, **kw):
    kw.setdefault("evidence", (ev(),))
    kw.setdefault("justification", "обоснование")
    kw.setdefault("confidence", 0.7)
    return L().CriterionScore(criterion_id=cid, status="scored", agent_score=score, rubric_version=version,
                              override=override, **kw)


def no_data(cid, version=1, **kw):
    return L().CriterionScore(criterion_id=cid, status="no_data", rubric_version=version,
                              no_data_reason=kw.pop("no_data_reason", "нет материалов"), **kw)


def override(score, reason="жюри не согласно", at="2026-10-25T10:00:00+00:00"):
    return L().OverrideInfo(score=score, reason=reason, at=at)


def flag(type_="plagiarism", **kw):
    return L().FlagInfo(type=type_, confidence=kw.pop("confidence", 0.9), note=kw.pop("note", "совпадает с репозиторием X"),
                        evidence=kw.pop("evidence", (ev(kind="url", ref="https://example.test/x"),)), **kw)


def sub(sid, team, scores=(), flags=(), cost=None):
    return L().SubmissionScores(submission_id=sid, team_name=team, scores=tuple(scores), flags=tuple(flags), cost_usd=cost)


def board(submissions, *, rub="default", **kw):
    lb = L()
    rub = rubric() if rub == "default" else rub
    kw.setdefault("project_id", "p1")
    kw.setdefault("generated_at", NOW)
    result = lb.build_leaderboard(rubric=rub, submissions=submissions, **kw)
    assert_valid("Leaderboard", result)
    return result


def row_of(result, sid):
    return next(r for r in result["rows"] if r["submission_id"] == sid)


def expected_total(items):
    from app.scoring import compute_score
    return compute_score([{"name": n, "score": s, "max_score": m, "weight": w} for n, s, m, w in items])["total"]


def full_scores(c1, c2, c3, c4):
    return [scored("c1", c1), scored("c2", c2), scored("c3", c3), scored("c4", c4)]


# ─────────────────────────────── итог ───────────────────────────────

def test_total_comes_from_compute_score_on_current_scores():
    result = board([sub("s1", "Alpha", full_scores(8, 4, 6, 7))])

    row = result["rows"][0]
    assert row["total"] == expected_total([("c1", 8, 10, 2), ("c2", 4, 5, 1), ("c3", 6, 10, 1), ("c4", 7, 10, 1)])
    assert row["complete"] is True
    assert row["rank"] == 1


def test_total_is_bit_for_bit_equal_to_scoring_compute_score():
    import struct

    result = board([sub("s1", "Alpha", full_scores(6.67, 3.33, 9.99, 0.01))])

    want = expected_total([("c1", 6.67, 10, 2), ("c2", 3.33, 5, 1), ("c3", 9.99, 10, 1), ("c4", 0.01, 10, 1)])
    assert struct.pack(">d", result["rows"][0]["total"]) == struct.pack(">d", want)


def test_no_data_and_not_evaluated_are_excluded_from_total_and_mark_incomplete():
    scores = [scored("c1", 8), no_data("c2")]   # c3 не оценивался, c4 — человек, правки нет
    result = board([sub("s1", "Alpha", scores)])

    row = result["rows"][0]
    assert row["total"] == expected_total([("c1", 8, 10, 2)])
    assert row["complete"] is False
    cells = row["cells"]
    assert cells["c1"]["status"] == "scored" and cells["c1"]["score"] == 8
    assert cells["c2"]["status"] == "no_data" and cells["c2"]["score"] is None
    assert cells["c3"]["status"] == "not_evaluated" and cells["c3"]["score"] is None
    assert cells["c4"]["status"] == "human_pending" and cells["c4"]["score"] is None


def test_cells_carry_max_score_and_follow_rubric_keys():
    result = board([sub("s1", "Alpha", full_scores(8, 4, 6, 7))])

    cells = result["rows"][0]["cells"]
    assert list(cells) == ["c1", "c2", "c3", "c4"]
    assert [cells[k]["max_score"] for k in cells] == [10, 5, 10, 10]
    assert all(cells[k]["overridden"] is False and cells[k]["stale"] is False for k in cells)


def test_submission_without_any_value_has_null_total_and_rank():
    result = board([sub("s1", "Alpha", [no_data("c1"), no_data("c2")])])

    row = result["rows"][0]
    assert row["total"] is None and row["rank"] is None and row["complete"] is False


def test_submission_without_scores_at_all():
    result = board([sub("s1", "Alpha")])

    row = result["rows"][0]
    assert row["total"] is None and row["rank"] is None
    assert {c["status"] for c in row["cells"].values()} == {"not_evaluated", "human_pending"}


def test_out_of_range_score_is_treated_as_no_data_not_counted_and_does_not_raise():
    scores = [scored("c1", 8), scored("c2", 99), scored("c3", -1), scored("c4", float("nan"))]
    result = board([sub("s1", "Alpha", scores)])

    row = result["rows"][0]
    assert row["total"] == expected_total([("c1", 8, 10, 2)])
    assert row["complete"] is False
    assert [row["cells"][k]["status"] for k in ("c2", "c3", "c4")] == ["no_data"] * 3


def test_entries_for_unknown_criteria_are_ignored_and_last_duplicate_wins():
    scores = [scored("zzz", 5), scored("c1", 2), scored("c1", 9)]
    result = board([sub("s1", "Alpha", scores)])

    row = result["rows"][0]
    assert "zzz" not in row["cells"]
    assert row["cells"]["c1"]["score"] == 9


# ─────────────────────────────── правки ───────────────────────────────

def test_override_replaces_agent_score_in_cell_and_total():
    scores = full_scores(4, 4, 6, 7)
    scores[0] = scored("c1", 4, override=override(9))
    result = board([sub("s1", "Alpha", scores)])

    row = result["rows"][0]
    assert row["cells"]["c1"]["score"] == 9 and row["cells"]["c1"]["overridden"] is True
    assert row["cells"]["c2"]["overridden"] is False
    assert row["total"] == expected_total([("c1", 9, 10, 2), ("c2", 4, 5, 1), ("c3", 6, 10, 1), ("c4", 7, 10, 1)])


def test_override_on_no_data_makes_the_cell_scored():
    scores = [no_data("c1", override=override(5)), scored("c2", 5), scored("c3", 5), scored("c4", 5)]
    result = board([sub("s1", "Alpha", scores)])

    row = result["rows"][0]
    assert row["cells"]["c1"]["status"] == "scored" and row["cells"]["c1"]["score"] == 5
    assert row["complete"] is True


def test_override_resolves_human_pending_criterion():
    entry = L().CriterionScore(criterion_id="c4", status="no_data", override=override(10), no_data_reason="ждёт жюри")
    result = board([sub("s1", "Alpha", [entry])])

    cell = result["rows"][0]["cells"]["c4"]
    assert cell["status"] == "scored" and cell["score"] == 10 and cell["overridden"] is True


def test_override_out_of_range_is_not_counted():
    scores = [scored("c1", 8, override=override(11))]
    result = board([sub("s1", "Alpha", scores)])

    cell = result["rows"][0]["cells"]["c1"]
    assert cell["status"] == "no_data" and cell["score"] is None
    assert result["rows"][0]["total"] is None


# ─────────────────────────────── ранги ───────────────────────────────

def test_ranks_descending_with_ties_share_a_place_and_gap_follows():
    subs = [
        sub("low", "Low", full_scores(5, 2, 5, 5)),
        sub("a", "A-team", full_scores(9, 4, 9, 9)),
        sub("b", "B-team", full_scores(9, 4, 9, 9)),
        sub("none", "Nothing", [no_data("c1")]),
        sub("mid", "Mid", full_scores(7, 3, 7, 7)),
    ]
    result = board(subs)

    ranks = {r["submission_id"]: r["rank"] for r in result["rows"]}
    assert ranks == {"a": 1, "b": 1, "mid": 3, "low": 4, "none": None}
    order = [r["submission_id"] for r in result["rows"]]
    assert order[-1] == "none"
    assert order[:2] == ["a", "b"]   # равные итоги — по названию команды


def test_incomplete_submission_with_partial_total_is_ranked():
    subs = [sub("full", "Full", full_scores(5, 2, 5, 5)), sub("part", "Part", [scored("c1", 10)])]
    result = board(subs)

    assert row_of(result, "part")["rank"] == 1 and row_of(result, "part")["complete"] is False
    assert row_of(result, "full")["rank"] == 2


def test_ties_are_decided_on_the_rounded_total():
    # 1/3 и 0.33333... нормируются в один итог 33.33
    one = [scored("c1", 10.0 / 3.0)]
    two = [scored("c1", 3.3333333)]
    result = board([sub("x", "X", one), sub("y", "Y", two)])

    assert {r["rank"] for r in result["rows"]} == {1}


# ─────────────────────────────── stale ───────────────────────────────

def test_stale_cells_and_stale_criteria():
    scores = [scored("c1", 8, version=1), scored("c2", 4, version=1), scored("c3", 6, version=2)]
    other = [scored("c1", 8, version=2), scored("c2", 4, version=1)]
    result = board([sub("s1", "Alpha", scores), sub("s2", "Beta", other)], rub=rubric(version=2),
                   changed_criteria={"c1": 2, "c3": 2})

    cells = row_of(result, "s1")["cells"]
    assert cells["c1"]["stale"] is True            # оценка версии 1, критерий изменился в версии 2
    assert cells["c2"]["stale"] is False           # критерий не менялся по смыслу
    assert cells["c3"]["stale"] is False           # оценка уже по версии 2
    assert row_of(result, "s2")["cells"]["c1"]["stale"] is False
    assert result["stale_criteria"] == ["c1"]
    assert result["rubric_version"] == 2


def test_stale_scores_still_count_in_total():
    result = board([sub("s1", "Alpha", [scored("c1", 8, version=1)])], rub=rubric(version=2), changed_criteria={"c1": 2})

    assert result["rows"][0]["total"] == expected_total([("c1", 8, 10, 2)])


def test_no_changed_criteria_means_nothing_is_stale():
    result = board([sub("s1", "Alpha", [scored("c1", 8, version=1)])], rub=rubric(version=5))

    assert result["stale_criteria"] == []
    assert result["rows"][0]["cells"]["c1"]["stale"] is False


def test_stale_flag_only_on_cells_with_a_value():
    result = board([sub("s1", "Alpha", [no_data("c1", version=1)])], rub=rubric(version=2), changed_criteria={"c1": 2})

    assert result["rows"][0]["cells"]["c1"]["stale"] is False
    assert result["stale_criteria"] == []


# ─────────────────────────────── сортировка и фильтры ───────────────────────────────

def three():
    return [
        sub("a", "Alpha", full_scores(9, 4, 9, 9), flags=[flag("plagiarism")]),
        sub("b", "Beta", full_scores(5, 2, 8, 5)),
        sub("c", "Gamma", [scored("c1", 7), scored("c2", 5)], flags=[flag("agent_failure", confidence=1.0)]),
        sub("d", "Delta", [no_data("c1")]),
    ]


def ids(result):
    return [r["submission_id"] for r in result["rows"]]


def test_default_sort_is_total_descending_with_nulls_last():
    assert ids(board(three())) == ["a", "c", "b", "d"]   # итоги 88, 80, 54, нет итога


def test_sort_total_ascending_keeps_nulls_last():
    result = board(three(), sort="total", order="asc")

    assert ids(result)[-1] == "d"
    totals = [r["total"] for r in result["rows"] if r["total"] is not None]
    assert totals == sorted(totals)


def test_sort_by_criterion_uses_cell_score_and_puts_missing_last():
    desc = board(three(), sort="c1", order="desc")
    asc = board(three(), sort="c1", order="asc")

    assert ids(desc) == ["a", "c", "b", "d"]    # 9, 7, 5, нет данных
    assert ids(asc) == ["b", "c", "a", "d"]     # 5, 7, 9, нет данных


def test_sort_by_criterion_with_missing_cells_in_the_middle_goes_last():
    result = board(three(), sort="c3", order="desc")

    assert ids(result)[:2] == ["a", "b"]
    assert set(ids(result)[2:]) == {"c", "d"}


def test_ranks_do_not_depend_on_sort_order():
    by_total = {r["submission_id"]: r["rank"] for r in board(three())["rows"]}
    by_name = {r["submission_id"]: r["rank"] for r in board(three(), sort="c2", order="asc")["rows"]}

    assert by_total == by_name


def test_filter_by_flag_keeps_original_ranks():
    result = board(three(), flag="agent_failure")

    assert ids(result) == ["c"]
    assert row_of(result, "c")["rank"] == 2   # место в полной таблице, а не среди отфильтрованных


def test_filter_by_flag_with_no_matches_gives_empty_rows():
    result = board(three(), flag="secret_exposed")

    assert result["rows"] == []
    assert [c["id"] for c in result["criteria"]] == ["c1", "c2", "c3", "c4"]


@pytest.mark.parametrize("kwargs", [
    {"sort": "no-such-criterion"}, {"order": "sideways"}, {"flag": "not_a_flag_type"},
])
def test_invalid_sort_order_or_flag_raise_value_error(kwargs):
    with pytest.raises(ValueError):
        L().build_leaderboard(project_id="p1", rubric=rubric(), submissions=three(), generated_at=NOW, **kwargs)


def test_flag_counts_are_grouped_by_type_and_sorted():
    flags = [flag("plagiarism"), flag("agent_failure"), flag("plagiarism", note="ещё один")]
    result = board([sub("s1", "Alpha", full_scores(5, 2, 5, 5), flags=flags)])

    assert result["rows"][0]["flags"] == [{"type": "agent_failure", "count": 1}, {"type": "plagiarism", "count": 2}]


def test_submission_without_flags_has_empty_flag_list():
    assert board([sub("s1", "Alpha")])["rows"][0]["flags"] == []


# ─────────────────────────────── стоимость, пустые случаи, заголовок ───────────────────────────────

def test_cost_is_sum_or_null_when_any_submission_has_no_data():
    full = board([sub("a", "A", cost=0.25), sub("b", "B", cost=0.5)])
    partial = board([sub("a", "A", cost=0.25), sub("b", "B", cost=None)])

    assert full["cost_usd"] == 0.75
    assert partial["cost_usd"] is None


def test_cost_sum_does_not_leak_float_noise():
    assert board([sub("a", "A", cost=0.1), sub("b", "B", cost=0.2)])["cost_usd"] == 0.3


def test_empty_project_without_submissions():
    result = board([])

    assert result["rows"] == [] and result["stale_criteria"] == []
    assert result["project_id"] == "p1" and result["rubric_version"] == 1 and result["generated_at"] == NOW
    assert [c["id"] for c in result["criteria"]] == ["c1", "c2", "c3", "c4"]
    assert result["cost_usd"] == 0.0


def test_project_without_confirmed_rubric():
    result = board([sub("s1", "Alpha")], rub=None)

    assert result["rubric_version"] is None and result["criteria"] == []
    row = result["rows"][0]
    assert row["cells"] == {} and row["total"] is None and row["rank"] is None and row["complete"] is False


def test_criteria_header_follows_rubric_order_and_fields():
    result = board([])

    assert result["criteria"][0] == {"id": "c1", "name": "Код", "weight": 2, "max_score": 10, "agent": "code"}
    assert result["criteria"][3]["agent"] == "human"


def test_build_leaderboard_is_pure_and_deterministic():
    subs = three()
    before = copy.deepcopy(subs)

    first = board(subs)
    second = board(subs)

    assert first == second
    assert subs == before


# ─────────────────────────────── схема на «большом» сценарии ───────────────────────────────

def test_kitchen_sink_scenario_validates_against_openapi_leaderboard_schema():
    scores_a = full_scores(8, 4, 6, 7)
    scores_a[0] = scored("c1", 4, version=1, override=override(9))
    subs = [
        sub("a", "Alpha", scores_a, flags=[flag("claim_mismatch"), flag("prompt_injection")], cost=1.5),
        sub("b", "Beta", [scored("c1", 3), no_data("c2")], flags=[flag("incomplete_materials")], cost=0.5),
        sub("c", "Gamma", [], cost=0.0),
    ]
    for order in ("asc", "desc"):
        for sort in ("total", "c1", "c2", "c3", "c4"):
            result = board(subs, rub=rubric(version=3), changed_criteria={"c1": 2}, sort=sort, order=order)
            assert len(result["rows"]) == 3
    assert board(subs, flag="claim_mismatch")["rows"][0]["submission_id"] == "a"


def test_schema_validator_is_actually_strict():
    good = board([sub("s1", "Alpha")])
    broken = {k: v for k, v in good.items() if k != "rows"}

    with pytest.raises(jsonschema.ValidationError):
        schema_validator("Leaderboard").validate(broken)
    wrong_cell = copy.deepcopy(good)
    wrong_cell["rows"][0]["cells"]["c1"]["status"] = "weird"
    with pytest.raises(jsonschema.ValidationError):
        schema_validator("Leaderboard").validate(wrong_cell)


# ─────────────────────────────── пояснение ───────────────────────────────

def crit(cid="c1"):
    return next(c for c in rubric().criteria if c.id == cid)


def explain(entry, *, cid="c1", flags=(), team="Alpha"):
    result = L().build_explanation(criterion=crit(cid), team_name=team, entry=entry, flags=tuple(flags))
    assert_valid("Explanation", result)
    return result


def test_explanation_for_scored_criterion():
    entry = scored(
        "c1", 8, justification="Хорошая архитектура", confidence=0.85, run_id="run-7", version=4,
        evidence=(ev("api/routes.py:40-88", quote="def create()"), ev("deck.pdf#4", kind="slide", available=False)),
    )
    other_flag = flag("plagiarism", criterion_id="c2")
    own_flag = flag("claim_mismatch", criterion_id="c1", related_url="https://example.test/y")
    result = explain(entry, flags=[other_flag, own_flag])

    assert result["criterion_id"] == "c1" and result["criterion_name"] == "Код" and result["team_name"] == "Alpha"
    assert result["status"] == "scored" and result["score"] == 8 and result["max_score"] == 10
    assert result["agent_score"] == 8 and result["override"] is None and result["agent"] == "code"
    assert result["justification"] == "Хорошая архитектура" and result["confidence"] == 0.85
    assert result["run_id"] == "run-7" and result["version"] == 4
    assert result["evidence"][0] == {"kind": "file", "ref": "api/routes.py:40-88", "quote": "def create()", "available": True}
    assert result["evidence"][1] == {"kind": "slide", "ref": "deck.pdf#4", "available": False}
    assert [f["type"] for f in result["flags"]] == ["claim_mismatch"]   # только флаги этого критерия
    assert result["flags"][0]["related_url"] == "https://example.test/y"
    assert result["flags"][0]["evidence"][0]["kind"] == "url"


def test_explanation_after_override_shows_both_scores():
    entry = scored("c1", 4, override=override(9, reason="проверили руками"), version=2)
    result = explain(entry)

    assert result["score"] == 9 and result["agent_score"] == 4
    assert result["override"] == {"score": 9, "reason": "проверили руками", "at": "2026-10-25T10:00:00+00:00"}
    assert result["status"] == "scored" and result["version"] == 2


def test_explanation_for_no_data_criterion():
    result = explain(no_data("c1", no_data_reason="репозиторий недоступен"))

    assert result["status"] == "no_data" and result["score"] is None and result["agent_score"] is None
    assert result["no_data_reason"] == "репозиторий недоступен"
    assert result["override"] is None


def test_explanation_for_human_criterion_without_entry_is_human_pending():
    result = explain(None, cid="c4")

    assert result["status"] == "human_pending" and result["score"] is None and result["agent"] == "human"
    assert result["evidence"] == [] and result["flags"] == []


def test_explanation_without_entry_for_agent_criterion_is_no_data_not_evaluated():
    result = explain(None, cid="c2")

    assert result["status"] == "no_data" and result["no_data_reason"] == "not_evaluated"
    assert result["version"] == 0 and result["max_score"] == 5


def test_explanation_invalid_agent_score_is_reported_as_no_data():
    result = explain(scored("c1", 77))

    assert result["status"] == "no_data" and result["score"] is None
    assert result["no_data_reason"] == "invalid_score"
    assert result["agent_score"] == 77   # исходное значение не теряется


def test_explanation_matches_leaderboard_cell():
    entry = scored("c1", 4, override=override(9))
    lb_cell = board([sub("s1", "Alpha", [entry])])["rows"][0]["cells"]["c1"]
    ex = explain(entry)

    assert (ex["status"], ex["score"], ex["max_score"]) == (lb_cell["status"], lb_cell["score"], lb_cell["max_score"])


def test_explanation_is_pure():
    entry = scored("c1", 8)
    flags = (flag("plagiarism", criterion_id="c1"),)
    before = copy.deepcopy((entry, flags))

    first = explain(entry, flags=flags)
    second = explain(entry, flags=flags)

    assert first == second and (entry, flags) == before
