from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

from intake import pipeline, similarity, web

ROOT = Path(__file__).resolve().parents[2]


def _work(tmp_path: Path, sid: str = "s1", files: dict[str, str] | None = None) -> tuple[Path, Path]:
    data = tmp_path / "data"
    directory = data / "projects" / "p1" / "submissions" / sid
    directory.mkdir(parents=True)
    for name, content in (files or {"main.py": "print(1)\n"}).items():
        (directory / name).parent.mkdir(parents=True, exist_ok=True)
        (directory / name).write_text(content, encoding="utf-8")
    return data, directory


def test_batch_archive_exposes_only_own_team_folder(tmp_path: Path) -> None:
    data, directory = _work(tmp_path, files={})
    raw = directory / "raw" / "m1"
    raw.mkdir(parents=True)
    with zipfile.ZipFile(raw / "batch.zip", "w") as handle:
        handle.writestr("Команда Альфа/a.py", "alpha = 1\n")
        handle.writestr("Команда Бета/b.py", "beta = 2\n")
    inventory = pipeline.run_pipeline(directory, directory, project_id="p1", submission_id="s1", team_name="Команда Альфа")
    names = sorted(p.name for p in (directory / "extracted").rglob("*.py"))
    assert names == ["a.py"], names
    assert next(m for m in inventory["materials"] if m["type"] == "archive")["extracted"]["file_count"] == 1


def test_fetch_connects_to_checked_address_not_to_a_second_dns_answer(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    answers = iter([[(2, 1, 6, "", ("93.184.216.34", 80))]])

    def resolver(host, port, *args, **kwargs):
        try:
            return next(answers)
        except StopIteration:
            return [(2, 1, 6, "", ("127.0.0.1", port))]

    seen: list = []

    def fake_connect(address, *args, **kwargs):
        seen.append(address[0])
        raise ConnectionRefusedError("stop")

    monkeypatch.setattr(socket, "getaddrinfo", resolver)
    monkeypatch.setattr(socket, "create_connection", fake_connect)
    with pytest.raises((web.FetchFailed, web.SSRFBlocked)):
        web.fetch_url("http://rebind.example.org/x", tmp_path / "out.bin", attempts=1)
    assert "127.0.0.1" not in seen and "rebind.example.org" not in seen


def test_carrier_grade_nat_range_is_blocked(tmp_path: Path) -> None:
    with pytest.raises(web.SSRFBlocked):
        web.fetch_url("http://100.64.0.1/meta", tmp_path / "out.bin", attempts=1)


def test_inventory_is_written_before_similarity_runs(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    data, directory = _work(tmp_path)
    seen: list[bool] = []

    def spy(project_id, works, target):
        seen.append((directory / "inventory.json").is_file())
        raise RuntimeError("slow comparison killed")

    monkeypatch.setattr(similarity, "write_similarity", spy)
    pipeline.run_pipeline(directory, directory, project_id="p1", submission_id="s1")
    assert seen == [True]


def test_similarity_update_is_serialized_with_a_lock(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import fcntl

    data, directory = _work(tmp_path)
    calls: list[int] = []
    real = fcntl.flock
    monkeypatch.setattr(pipeline.fcntl, "flock", lambda fd, op: (calls.append(op), real(fd, op))[1])
    pipeline.run_pipeline(directory, directory, project_id="p1", submission_id="s1")
    assert fcntl.LOCK_EX in calls
    assert (data / "projects" / "p1" / "similarity.json").is_file()


def test_directories_without_inventory_are_not_compared(tmp_path: Path) -> None:
    shared = "\n".join(f"v{i} = compute({i * 1009 + 311}) + {i * 503 + 607}" for i in range(60))
    data, first = _work(tmp_path, "s1", {"main.py": shared})
    _work(tmp_path, "upload-temp", {"copy.py": shared})
    pipeline.run_pipeline(first, first, project_id="p1", submission_id="s1")
    doc = json.loads((data / "projects" / "p1" / "similarity.json").read_text(encoding="utf-8"))
    assert doc["pairs"] == []


def test_cli_without_ids_derives_them_from_layout(tmp_path: Path) -> None:
    _data, directory = _work(tmp_path, "s77")
    env = {"PATH": os.environ["PATH"], "PYTHONPATH": str(ROOT)}
    done = subprocess.run([sys.executable, "-m", "intake", str(directory), "--out", str(directory)], cwd=ROOT, env=env, capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    inventory = json.loads((directory / "inventory.json").read_text(encoding="utf-8"))
    assert (inventory["project_id"], inventory["submission_id"]) == ("p1", "s77")
    assert inventory["materials"][0]["source"]["path"].startswith("projects/p1/submissions/s77/")


def test_malformed_link_type_does_not_abort_other_links(tmp_path: Path) -> None:
    _data, directory = _work(tmp_path)
    (directory / "links.json").write_text(json.dumps([{"url": "http://127.0.0.1/a", "type": ["x"]}, {"url": "http://127.0.0.1/b", "type": {"a": 1}}, {"url": "http://127.0.0.1/c"}]), encoding="utf-8")
    inventory = pipeline.run_pipeline(directory, directory, project_id="p1", submission_id="s1")
    assert len([m for m in inventory["materials"] if m["source"]["kind"] == "url"]) == 3
