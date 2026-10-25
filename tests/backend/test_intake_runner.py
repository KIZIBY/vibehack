"""T031 (часть): запуск intake подпроцессом ``app.services.intake_runner``. Тесты написаны ДО реализации (RED).
Вместо настоящего intake — фейковый скрипт во временном каталоге (``command=[sys.executable, fake]``).

Контракт:
- ``IntakeRunner(command=None, timeout=300.0, max_output_bytes=65536, cpu_seconds=240, memory_bytes=2*1024**3,
  max_open_files=256)``; ``await run(submission_dir, out_dir) -> dict`` — опись из ``<out_dir>/inventory.json``,
  проверенная по ``contracts/inventory.schema.json``;
- аргументы подпроцессу: ``<submission_dir> --out <out_dir>``; чистое окружение (PATH, LANG, HOME=временный
  каталог), свой process group, на POSIX лимиты CPU/AS/NOFILE;
- ``IntakeFailed(Exception)`` с ``reason``: ``timeout`` (убита вся группа), ``exit_code`` (+ ``returncode``,
  ``stderr_tail`` не длиннее ``max_output_bytes``), ``no_inventory``, ``bad_inventory``, ``spawn_failed``.

Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import textwrap
import time
from pathlib import Path

import jsonschema
import pytest

REPO = Path(__file__).resolve().parents[2]
SCHEMA = json.loads((REPO / "specs" / "001-ai-judge-platform" / "contracts" / "inventory.schema.json").read_text(encoding="utf-8"))

VALID_INVENTORY = {
    "schema_version": "1",
    "submission_id": "sub-1",
    "project_id": "proj-1",
    "team_name": "Команда",
    "created_at": "2026-10-25T10:00:00Z",
    "materials": [],
    "completeness": {"status": "complete", "required": [], "missing": []},
}


def run(coro):
    return asyncio.run(coro)


def write_fake(tmp_path: Path, body: str, name: str = "fake_intake.py") -> Path:
    path = tmp_path / name
    header = textwrap.dedent('''
        import json, os, sys, time
        from pathlib import Path
        submission_dir = Path(sys.argv[1])
        assert sys.argv[2] == "--out"
        out_dir = Path(sys.argv[3])
        out_dir.mkdir(parents=True, exist_ok=True)
        INVENTORY = json.loads(%r)
        def write_inventory(data=None):
            (out_dir / "inventory.json").write_text(json.dumps(INVENTORY if data is None else data), encoding="utf-8")
    ''' % json.dumps(VALID_INVENTORY))
    path.write_text(header + textwrap.dedent(body), encoding="utf-8")
    return path


def runner(fake: Path, **kwargs):
    from app.services.intake_runner import IntakeRunner
    return IntakeRunner(command=[sys.executable, str(fake)], **kwargs)


def dirs(tmp_path: Path):
    submission = tmp_path / "submission"
    out = tmp_path / "out"
    submission.mkdir()
    return submission, out


def failure(tmp_path: Path, body: str, **kwargs):
    from app.services.intake_runner import IntakeFailed
    submission, out = dirs(tmp_path)
    with pytest.raises(IntakeFailed) as info:
        run(runner(write_fake(tmp_path, body), **kwargs).run(submission, out))
    return info.value


def test_sample_inventory_is_valid():
    jsonschema.validate(VALID_INVENTORY, SCHEMA)


def test_default_command_and_signature():
    from app.services.intake_runner import IntakeRunner
    r = IntakeRunner()
    assert (r.timeout, r.max_output_bytes, r.cpu_seconds, r.memory_bytes, r.max_open_files) == (
        300.0, 65536, 240, 2 * 1024 ** 3, 256)
    assert r.build_command("/s", "/o") == [sys.executable, "-m", "intake", "/s", "--out", "/o"]


def test_success_returns_inventory(tmp_path):
    submission, out = dirs(tmp_path)
    fake = write_fake(tmp_path, """
        (out_dir / "argv.txt").write_text("\\n".join(sys.argv[1:]))
        write_inventory()
    """)
    result = run(runner(fake).run(submission, out))
    assert result == VALID_INVENTORY
    assert (out / "argv.txt").read_text().split("\n") == [str(submission), "--out", str(out)]


def test_stale_inventory_is_not_trusted(tmp_path):
    from app.services.intake_runner import IntakeFailed
    submission, out = dirs(tmp_path)
    out.mkdir()
    (out / "inventory.json").write_text(json.dumps(VALID_INVENTORY))
    fake = write_fake(tmp_path, "pass")
    with pytest.raises(IntakeFailed) as info:
        run(runner(fake).run(submission, out))
    assert info.value.reason == "no_inventory"


def test_missing_inventory(tmp_path):
    error = failure(tmp_path, "pass")
    assert error.reason == "no_inventory"


@pytest.mark.parametrize("body", [
    '(out_dir / "inventory.json").write_text("{not json")',
    '(out_dir / "inventory.json").write_text("[]")',
    'write_inventory({k: v for k, v in INVENTORY.items() if k != "team_name"})',
    'write_inventory(dict(INVENTORY, schema_version="2"))',
    'write_inventory(dict(INVENTORY, unexpected=1))',
    '(out_dir / "inventory.json").write_bytes(b"\\xff\\xfe\\x00")',
])
def test_bad_inventory(tmp_path, body):
    assert failure(tmp_path, body).reason == "bad_inventory"


def test_inventory_symlink_rejected(tmp_path):
    outside = tmp_path / "outside.json"
    outside.write_text(json.dumps(VALID_INVENTORY))
    error = failure(tmp_path, f'os.symlink({str(outside)!r}, out_dir / "inventory.json")')
    assert error.reason == "bad_inventory"


def test_nonzero_exit_has_reason_and_stderr_tail(tmp_path):
    error = failure(tmp_path, """
        sys.stderr.write("boom-marker\\n")
        write_inventory()
        sys.exit(3)
    """)
    assert error.reason == "exit_code" and error.returncode == 3
    assert "boom-marker" in error.stderr_tail
    assert "boom-marker" in str(error) or "exit_code" in str(error)
    assert str(tmp_path) not in str(error)          # пути машины в сообщение не попадают
    assert sys.executable not in str(error)


def test_stderr_tail_truncated_to_limit(tmp_path):
    error = failure(tmp_path, """
        sys.stderr.write("head-marker\\n" + "x" * 200000 + "\\ntail-marker\\n")
        sys.exit(1)
    """, max_output_bytes=1000)
    assert len(error.stderr_tail.encode("utf-8")) <= 1000
    assert "tail-marker" in error.stderr_tail and "head-marker" not in error.stderr_tail


def test_huge_output_does_not_block_or_break(tmp_path):
    submission, out = dirs(tmp_path)
    fake = write_fake(tmp_path, """
        sys.stdout.write("o" * (8 * 1024 * 1024))
        sys.stdout.flush()
        sys.stderr.write("e" * (8 * 1024 * 1024))
        sys.stderr.flush()
        write_inventory()
    """)
    started = time.monotonic()
    result = run(runner(fake, max_output_bytes=1000, timeout=30).run(submission, out))
    assert result == VALID_INVENTORY
    assert time.monotonic() - started < 25


def test_spawn_failure(tmp_path):
    from app.services.intake_runner import IntakeFailed, IntakeRunner
    submission, out = dirs(tmp_path)
    with pytest.raises(IntakeFailed) as info:
        run(IntakeRunner(command=[str(tmp_path / "no-such-binary")]).run(submission, out))
    assert info.value.reason == "spawn_failed"


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # зомби считаем мёртвым: статус читаем через ps
    import subprocess
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


def test_timeout_kills_whole_process_group(tmp_path):
    from app.services.intake_runner import IntakeFailed
    submission, out = dirs(tmp_path)
    fake = write_fake(tmp_path, f"""
        import subprocess
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        Path({str(tmp_path / 'pids.json')!r}).write_text(json.dumps([os.getpid(), child.pid]))
        time.sleep(60)
    """)
    started = time.monotonic()
    with pytest.raises(IntakeFailed) as info:
        run(runner(fake, timeout=0.5).run(submission, out))
    assert info.value.reason == "timeout"
    assert time.monotonic() - started < 10
    pids = json.loads((tmp_path / "pids.json").read_text())
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and any(alive(pid) for pid in pids):
        time.sleep(0.05)
    assert not any(alive(pid) for pid in pids), pids


def test_clean_environment(tmp_path, monkeypatch):
    monkeypatch.setenv("SECRET_TEST_VALUE", "hunter2-do-not-leak")
    monkeypatch.setenv("JUDGE_SESSION_SECRET", "another-secret-value")
    monkeypatch.setenv("PYTHONPATH", str(tmp_path))
    submission, out = dirs(tmp_path)
    fake = write_fake(tmp_path, """
        (out_dir / "env.json").write_text(json.dumps(dict(os.environ)))
        write_inventory()
    """)
    run(runner(fake).run(submission, out))
    env = json.loads((out / "env.json").read_text())
    assert {"PATH", "LANG", "HOME"} <= set(env)
    assert set(env) <= {"PATH", "LANG", "HOME", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"}, sorted(env)
    assert "hunter2-do-not-leak" not in json.dumps(env) and "another-secret-value" not in json.dumps(env)
    assert env["HOME"] != os.environ.get("HOME")
    assert not Path(env["HOME"]).exists()           # временный HOME убран после запуска


@pytest.mark.skipif(os.name != "posix", reason="resource.setrlimit есть только на POSIX")
def test_resource_limits_applied(tmp_path):
    submission, out = dirs(tmp_path)
    fake = write_fake(tmp_path, """
        import resource
        limits = {name: resource.getrlimit(getattr(resource, "RLIMIT_" + name)) for name in ("NOFILE", "CPU", "AS")}
        (out_dir / "limits.json").write_text(json.dumps(limits))
        write_inventory()
    """)
    memory = 4 * 1024 ** 3
    run(runner(fake, max_open_files=64, cpu_seconds=123, memory_bytes=memory).run(submission, out))
    limits = json.loads((out / "limits.json").read_text())
    assert limits["NOFILE"][0] == 64
    assert limits["CPU"][0] == 123
    if sys.platform != "darwin":            # на macOS RLIMIT_AS ядром не поддерживается
        assert limits["AS"][0] == memory


@pytest.mark.skipif(os.name != "posix", reason="process group есть только на POSIX")
def test_runs_in_own_process_group(tmp_path):
    submission, out = dirs(tmp_path)
    fake = write_fake(tmp_path, """
        (out_dir / "pg.json").write_text(json.dumps([os.getpgrp(), os.getpid()]))
        write_inventory()
    """)
    run(runner(fake).run(submission, out))
    pgrp, pid = json.loads((out / "pg.json").read_text())
    assert pgrp == pid and pgrp != os.getpgrp()
