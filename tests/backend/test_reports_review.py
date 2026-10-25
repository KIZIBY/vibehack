"""Находки ревью T028 (P0/P1 про безопасность и данные). Тесты написаны ДО правок (RED).

- задача ``run_task`` из БД — источник истины: ``submission_id``, ``role``, ``run_id`` и версия рубрики берутся из
  строк ``run_task`` / ``run``, а не из переданного словаря (иначе подмена полей пишет оценки чужой работе);
- отчёт читается без следования символическим ссылкам на ЛЮБОМ уровне пути (в том числе подменённым каталогом);
- два одновременных приёма одной задачи пишут результат один раз.
"""
from __future__ import annotations

import json
import threading

import pytest
from test_reports import (  # noqa: F401  (хелперы тестов T028)
    OTHER_SUB, RUBRIC_V, SUB, Env, assert_agent_failure, doc, flag, score, write_report,
)


@pytest.fixture
def env(tmp_path):
    return Env(tmp_path)


def test_db_row_is_authoritative_over_the_passed_dictionary(env):
    task = env.task("code")
    write_report(env, task, doc(task, [score("C_CODE_A", 5), score("C_CODE_B", 3)]))
    forged = dict(task, submission_id=OTHER_SUB, role="design", rubric_version=2, run_id="OTHER-RUN")
    result = env.ingest(forged)
    assert result["accepted"] == 2 and result["rejected"] == []
    rows = env.scores(task)
    assert set(rows) == {"C_CODE_A", "C_CODE_B"}
    assert all(r["submission_id"] == SUB and r["rubric_version"] == RUBRIC_V for r in rows.values())
    assert env.rows("SELECT count(*) AS n FROM criterion_score WHERE submission_id = :s", s=OTHER_SUB)[0]["n"] == 0


def test_reports_directory_replaced_by_symlink_inside_data_dir_is_not_followed(env):
    task = env.task("code")
    real = env.data_dir / "runs" / "REAL" / "reports"
    real.mkdir(parents=True)
    (real / "code.json").write_text(json.dumps(doc(task, [score("C_CODE_A", 5), score("C_CODE_B", 3)])), encoding="utf-8")
    link = env.data_dir / "runs" / task["run_id"] / "reports"
    link.parent.mkdir(parents=True)
    link.symlink_to(real, target_is_directory=True)
    result = env.ingest(task)
    assert_agent_failure(env, task, result, ("C_CODE_A", "C_CODE_B"))


def test_run_directory_replaced_by_symlink_inside_data_dir_is_not_followed(env):
    task = env.task("code")
    real = env.data_dir / "runs" / "REAL"
    (real / "reports").mkdir(parents=True)
    (real / "reports" / "code.json").write_text(
        json.dumps(doc(task, [score("C_CODE_A", 5), score("C_CODE_B", 3)])), encoding="utf-8")
    (env.data_dir / "runs" / task["run_id"]).symlink_to(real, target_is_directory=True)
    assert_agent_failure(env, task, env.ingest(task), ("C_CODE_A", "C_CODE_B"))


def test_concurrent_ingest_of_the_same_task_writes_once(env, monkeypatch):
    import app.services.reports as reports

    task = env.task("code")
    write_report(env, task, doc(task, [score("C_CODE_A", 5), score("C_CODE_B", 3)], [flag()]))
    barrier = threading.Barrier(2)
    original = reports._load_document

    def synchronized(*args, **kwargs):
        try:   # обе нити дошли до чтения отчёта, не успев ничего записать
            barrier.wait(timeout=1.5)
        except threading.BrokenBarrierError:
            pass
        return original(*args, **kwargs)

    monkeypatch.setattr(reports, "_load_document", synchronized)
    results, errors = [], []

    def worker():
        try:
            results.append(env.ingest(task))
        except Exception as exc:  # noqa: BLE001
            errors.append(exc)

    threads = [threading.Thread(target=worker) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(30)
    assert not errors, errors
    assert env.counts() == (2, 1, 0)
    assert len(results) == 2 and results[0] == results[1]
