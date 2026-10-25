"""T031 (остаток): вызов intake из сервиса работ — ``app.services.intake_flow.run_intake``. Тесты написаны ДО реализации (RED).

Контракт:
- ``await run_intake(app, project_id, submission_id)`` (после создания работы, в фоне): ``pending -> running`` одним
  ``UPDATE … WHERE intake_status = 'pending'`` (проигравший гонку или работа не в ``pending`` выходит, не вызывая intake);
  ``IntakeRunner.run(<projects/<pid>/submissions/<sid>>, <тот же каталог>)`` из ``get_intake_runner(app)``;
  при успехе: ``inventory_path`` (относительный), ``completeness`` и ``missing`` из описи, ``material.status/reason/size_bytes/type`` по
  ``material_id`` (иначе по ``source.url``/``source.path``), материалы описи без строки в БД добавляются, ``intake_status=ready``;
  затем системное сообщение ``inventory_ready`` и событие ``submission.inventory_ready`` ``{submission_id, completeness}``;
  при ``IntakeFailed``: ``intake_status=failed``, короткая причина в лог ERROR (без stderr и путей машины), исключение наружу не уходит,
  ни сообщения, ни события;
- перед запуском в каталоге работы лежит ``links.json`` со ссылками работы (``[{"material_id", "type", "url"}]``).

Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import asyncio
import json
import logging
import sys
import textwrap
from pathlib import Path

import pytest
import sqlalchemy as sa
from alembic import command
from alembic.config import Config

REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / "backend"
SESSION_SECRET = "session-secret-ZK7"      # выдуманное значение
SECRET_STDERR = "stderr-marker-QX91"


def make_cfg(url: str) -> Config:
    cfg = Config(str(BACKEND / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND / "migrations"))
    cfg.set_main_option("sqlalchemy.url", url)
    return cfg


def make_app(tmp_path):
    from app.config import load_settings
    from app.main import create_app
    url = f"sqlite:///{tmp_path / 'db.sqlite'}"
    command.upgrade(make_cfg(url), "head")
    settings = load_settings({"JUDGE_DATABASE_URL": url, "JUDGE_SESSION_SECRET": SESSION_SECRET,
                              "JUDGE_DATA_DIR": str(tmp_path / "data")})
    return create_app(settings)


@pytest.fixture
def app(tmp_path):
    return make_app(tmp_path)


def run(coro):
    return asyncio.run(coro)


def sql(app, statement: str, params: dict | None = None):
    with app.state.engine.begin() as conn:
        return conn.execute(sa.text(statement), params or {})


def rows(app, statement: str, params: dict | None = None) -> list[dict]:
    with app.state.engine.connect() as conn:
        return [dict(r) for r in conn.execute(sa.text(statement), params or {}).mappings()]


def seed(app, team="Команда", *, status="pending", materials=()):
    """Проект и работа напрямую в БД; ``materials`` — кортежи (id, type, source_kind, source_ref)."""
    from app.common import new_id, utc_now_iso
    now = utc_now_iso()
    project_id, submission_id = new_id(), new_id()
    sql(app, "INSERT INTO project (id, name, type, status, agents, required_materials, retention_days, last_activity_at, "
             "version, created_at, updated_at) VALUES (:id, 'P', 'other', 'intake', '[]', '[]', 7, :now, 1, :now, :now)",
        {"id": project_id, "now": now})
    sql(app, "INSERT INTO submission (id, project_id, team_name, intake_status, completeness, version, created_at) "
             "VALUES (:id, :p, :team, :status, 'unknown', 1, :now)",
        {"id": submission_id, "p": project_id, "team": team, "status": status, "now": now})
    for material_id, type_, kind, ref in materials:
        sql(app, "INSERT INTO material (id, submission_id, type, source_kind, source_ref, status) "
                 "VALUES (:id, :s, :t, :k, :r, 'available')", {"id": material_id, "s": submission_id, "t": type_, "k": kind, "r": ref})
    return project_id, submission_id


def inventory(project_id, submission_id, materials=(), *, status="complete", missing=()):
    return {"schema_version": "1", "submission_id": submission_id, "project_id": project_id, "team_name": "Команда",
            "created_at": "2026-10-25T10:00:00Z", "materials": list(materials),
            "completeness": {"status": status, "required": ["repository"], "missing": list(missing)}}


def fake_script(tmp_path: Path, body: str) -> Path:
    path = tmp_path / "fake_intake.py"
    path.write_text(textwrap.dedent('''
        import json, sys
        from pathlib import Path
        submission_dir = Path(sys.argv[1])
        assert sys.argv[2] == "--out"
        out_dir = Path(sys.argv[3])
        out_dir.mkdir(parents=True, exist_ok=True)
    ''') + textwrap.dedent(body), encoding="utf-8")
    return path


def install_runner(app, script: Path):
    from app.services.intake_runner import IntakeRunner
    app.state.intake_runner = IntakeRunner(command=[sys.executable, str(script)])


def ok_script(tmp_path, data: dict, counter: Path | None = None) -> Path:
    count = f"open({str(counter)!r}, 'a').write('x')" if counter else "pass"
    return fake_script(tmp_path, f"""
        {count}
        (out_dir / "inventory.json").write_text({json.dumps(json.dumps(data))}, encoding="utf-8")
    """)


def submission(app, submission_id):
    return rows(app, "SELECT * FROM submission WHERE id = :id", {"id": submission_id})[0]


def collect_events(app, project_id):
    from app.routers.events import get_event_bus

    async def go():
        subscription = get_event_bus(app).subscribe(project_id, 0)
        found = []
        try:
            while True:
                found.append(await asyncio.wait_for(subscription.__anext__(), 0.05))
        except asyncio.TimeoutError:
            pass
        finally:
            await subscription.aclose()
        return found

    return run(go())


# ─────────────────────────────── успех ───────────────────────────────

def test_success_fills_submission_materials_message_and_event(app, tmp_path):
    from app.services.intake_flow import run_intake
    old_repo, old_deck = "M" * 26, "N" * 26
    project_id, sub_id = seed(app, "Команда", materials=[
        (old_repo, "host", "url", "https://github.com/a/b"),
        (old_deck, "other", "upload", "projects/x/submissions/y/raw/deck.pdf"),
    ])
    data = inventory(project_id, sub_id, [
        {"material_id": old_repo, "type": "repository", "source": {"kind": "url", "url": "https://github.com/a/b"},
         "status": "partial", "reason": "репозиторий обрезан до исходников", "size_bytes": 1234},
        {"material_id": "abc123", "type": "presentation", "source": {"kind": "upload", "path": "projects/x/submissions/y/raw/deck.pdf"},
         "status": "available", "size_bytes": 99},
        {"material_id": "extra-1", "type": "screencast", "source": {"kind": "url", "url": "https://v.example.org/demo"},
         "status": "unavailable", "reason": "видео недоступно"},
    ], status="incomplete", missing=["host"])
    install_runner(app, ok_script(tmp_path, data))
    run(run_intake(app, project_id, sub_id))

    sub = submission(app, sub_id)
    assert (sub["intake_status"], sub["completeness"]) == ("ready", "incomplete")
    assert json.loads(sub["missing"]) == ["host"]
    assert sub["inventory_path"] == f"projects/{project_id}/submissions/{sub_id}/inventory.json"
    assert (tmp_path / "data" / sub["inventory_path"]).is_file()

    by_id = {m["id"]: m for m in rows(app, "SELECT * FROM material WHERE submission_id = :s", {"s": sub_id})}
    assert len(by_id) == 3
    repo = by_id[old_repo]
    assert (repo["type"], repo["status"], repo["reason"], repo["size_bytes"]) == ("repository", "partial", "репозиторий обрезан до исходников", 1234)
    deck = by_id[old_deck]                     # сопоставлен по источнику (material_id в описи другой)
    assert (deck["type"], deck["status"], deck["size_bytes"]) == ("presentation", "available", 99)
    new = next(m for m in by_id.values() if m["id"] not in (old_repo, old_deck))
    assert len(new["id"]) == 26 and (new["type"], new["source_kind"], new["source_ref"], new["status"], new["reason"]) == (
        "screencast", "url", "https://v.example.org/demo", "unavailable", "видео недоступно")

    messages = rows(app, "SELECT * FROM message WHERE project_id = :p", {"p": project_id})
    assert len(messages) == 1 and (messages[0]["author"], messages[0]["kind"]) == ("system", "inventory_ready")
    assert "Команда" in messages[0]["text"] and "не хватает" in messages[0]["text"]

    events = collect_events(app, project_id)
    ready = [e for e in events if e.type == "submission.inventory_ready"]
    assert len(ready) == 1 and ready[0].data == {"submission_id": sub_id, "completeness": "incomplete"}


def test_complete_inventory_message_says_so(app, tmp_path):
    from app.services.intake_flow import run_intake
    project_id, sub_id = seed(app, "Альфа")
    install_runner(app, ok_script(tmp_path, inventory(project_id, sub_id)))
    run(run_intake(app, project_id, sub_id))
    text = rows(app, "SELECT text FROM message WHERE project_id = :p", {"p": project_id})[0]["text"]
    assert "Альфа" in text and "полная" in text and "не хватает" not in text
    assert json.loads(submission(app, sub_id)["missing"]) == []


def test_intake_gets_the_submission_directory_and_links_manifest(app, tmp_path):
    from app.services.intake_flow import run_intake
    project_id, sub_id = seed(app, materials=[("L" * 26, "repository", "url", "https://github.com/a/b"),
                                              ("U" * 26, "other", "upload", "projects/p/submissions/s/raw/U/a.txt")])
    seen = tmp_path / "seen.json"
    script = fake_script(tmp_path, f"""
        links = json.loads((submission_dir / "links.json").read_text(encoding="utf-8"))
        Path({str(seen)!r}).write_text(json.dumps({{"sub": str(submission_dir), "out": str(out_dir), "links": links}}))
        (out_dir / "inventory.json").write_text({json.dumps(json.dumps(inventory(project_id, sub_id)))}, encoding="utf-8")
    """)
    install_runner(app, script)
    run(run_intake(app, project_id, sub_id))
    got = json.loads(seen.read_text(encoding="utf-8"))
    expected = (tmp_path / "data" / "projects" / project_id / "submissions" / sub_id).resolve()
    assert Path(got["sub"]).resolve() == expected and Path(got["out"]).resolve() == expected
    assert got["links"] == [{"material_id": "L" * 26, "type": "repository", "url": "https://github.com/a/b"}]


# ─────────────────────────────── сбой ───────────────────────────────

@pytest.mark.parametrize("body", [
    f'sys.stderr.write("{SECRET_STDERR}"); sys.exit(3)',          # ненулевой код
    "pass",                                                       # нет описи
    '(out_dir / "inventory.json").write_text("{not json")',       # невалидная опись
])
def test_failure_marks_failed_logs_error_and_stays_quiet(app, tmp_path, caplog, body):
    from app.services.intake_flow import run_intake
    project_id, sub_id = seed(app, "Команда")
    install_runner(app, fake_script(tmp_path, body))
    with caplog.at_level(logging.DEBUG):
        run(run_intake(app, project_id, sub_id))          # исключение наружу не уходит
    sub = submission(app, sub_id)
    assert sub["intake_status"] == "failed" and sub["inventory_path"] is None and sub["completeness"] == "unknown"
    errors = [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert errors, "причина сбоя должна попасть в лог ERROR"
    logged = "\n".join(r.getMessage() for r in caplog.records)
    assert SECRET_STDERR not in logged and str(tmp_path) not in logged
    assert rows(app, "SELECT id FROM message") == []
    assert collect_events(app, project_id) == []


def test_runner_crash_with_unexpected_error_still_marks_failed(app, tmp_path):
    from app.services.intake_flow import run_intake

    class Exploding:
        async def run(self, *args):
            raise RuntimeError("неожиданный сбой")

    project_id, sub_id = seed(app)
    app.state.intake_runner = Exploding()
    run(run_intake(app, project_id, sub_id))
    assert submission(app, sub_id)["intake_status"] == "failed"


# ─────────────────────────────── защита от двойного запуска ───────────────────────────────

def test_concurrent_runs_start_intake_once(app, tmp_path):
    from app.services.intake_flow import run_intake
    project_id, sub_id = seed(app)
    counter = tmp_path / "count.txt"
    script = fake_script(tmp_path, f"""
        import time
        open({str(counter)!r}, "a").write("x")
        time.sleep(0.3)
        (out_dir / "inventory.json").write_text({json.dumps(json.dumps(inventory(project_id, sub_id)))}, encoding="utf-8")
    """)
    install_runner(app, script)

    async def both():
        await asyncio.gather(run_intake(app, project_id, sub_id), run_intake(app, project_id, sub_id))

    run(both())
    assert counter.read_text() == "x"
    assert submission(app, sub_id)["intake_status"] == "ready"
    assert len(rows(app, "SELECT id FROM message")) == 1


@pytest.mark.parametrize("status", ["running", "ready", "failed"])
def test_run_skips_submission_not_in_pending(app, tmp_path, status):
    from app.services.intake_flow import run_intake
    project_id, sub_id = seed(app, status=status)
    counter = tmp_path / "count.txt"
    install_runner(app, ok_script(tmp_path, inventory(project_id, sub_id), counter))
    run(run_intake(app, project_id, sub_id))
    assert not counter.exists() and submission(app, sub_id)["intake_status"] == status
    assert rows(app, "SELECT id FROM message") == []


def test_unknown_or_deleted_submission_is_a_quiet_noop(app, tmp_path):
    from app.services.intake_flow import run_intake
    project_id, sub_id = seed(app)
    counter = tmp_path / "count.txt"
    install_runner(app, ok_script(tmp_path, inventory(project_id, sub_id), counter))
    run(run_intake(app, project_id, "NOPE"))
    sql(app, "UPDATE submission SET deleted_at = :t WHERE id = :id", {"t": "2026-10-25T00:00:00+00:00", "id": sub_id})
    run(run_intake(app, project_id, sub_id))
    assert not counter.exists()
    assert submission(app, sub_id)["intake_status"] == "pending"
