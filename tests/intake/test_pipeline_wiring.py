from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import zipfile
from pathlib import Path

import jsonschema
import pytest

from intake import documents, pipeline, repo

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / "specs" / "001-ai-judge-platform" / "contracts"
FIXTURES = ROOT / "tests" / "fixtures" / "submissions"


def _schema_check(doc: dict) -> None:
    schema = json.loads((CONTRACTS / "inventory.schema.json").read_text(encoding="utf-8"))
    jsonschema.validate(doc, schema, format_checker=jsonschema.FormatChecker())


def _work(tmp_path: Path, pid: str = "p1", sid: str = "s1", files: dict[str, str | bytes] | None = None) -> tuple[Path, Path]:
    data = tmp_path / "data"
    directory = data / "projects" / pid / "submissions" / sid
    directory.mkdir(parents=True)
    for name, content in (files or {"README.md": "# Проект\nописание\n", "main.py": "print('hi')\n"}).items():
        (directory / name).parent.mkdir(parents=True, exist_ok=True)
        (directory / name).write_bytes(content if isinstance(content, bytes) else content.encode())
    return data, directory


def _run(directory: Path, **kwargs) -> dict:
    kwargs.setdefault("project_id", "p1")
    kwargs.setdefault("submission_id", "s1")
    return pipeline.run_pipeline(directory, directory, **kwargs)


def _no_network(monkeypatch: pytest.MonkeyPatch) -> None:
    def fail(*args, **kwargs):
        raise socket.gaierror("no network")

    monkeypatch.setattr(socket, "getaddrinfo", fail)


def test_files_are_classified_and_paths_are_relative_to_data_root(tmp_path: Path) -> None:
    data, directory = _work(tmp_path)
    inventory = _run(directory)
    _schema_check(inventory)
    by_name = {Path(m["source"]["path"]).name: m for m in inventory["materials"]}
    assert set(by_name) == {"README.md", "main.py"}            # inventory.json, links.json, extracted/ — не материалы
    assert by_name["README.md"]["type"] == "document" and by_name["main.py"]["type"] == "code_file"
    for material in inventory["materials"]:
        assert material["source"]["path"].startswith("projects/p1/submissions/s1/")
        assert material["material_id"].startswith("projects/p1/submissions/s1/")
        assert (data / material["source"]["path"]).is_file()


def test_document_text_is_extracted_and_path_is_data_root_relative(tmp_path: Path) -> None:
    data, directory = _work(tmp_path)
    inventory = _run(directory)
    readme = next(m for m in inventory["materials"] if m["source"]["path"].endswith("README.md"))
    text_path = readme["extracted"]["text_path"]
    assert text_path.startswith("projects/p1/submissions/s1/")
    assert "описание" in (data / text_path).read_text(encoding="utf-8")


def test_brief_in_extracted_subdir_gets_text_path_inside_out_dir(tmp_path: Path) -> None:
    data = tmp_path / "data"
    brief = data / "projects" / "p1" / "briefs" / "b1"
    brief.mkdir(parents=True)
    (brief / "criteria.md").write_text("# Критерии\n- код\n", encoding="utf-8")
    out = brief / "extracted"
    inventory = pipeline.run_pipeline(brief, out)
    text_path = inventory["materials"][0]["extracted"]["text_path"]
    target = (data / text_path).resolve()
    assert target.is_file() and target.is_relative_to(out.resolve())
    assert (out / "inventory.json").is_file()


def test_unreachable_repository_link_is_unavailable_with_reason(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _no_network(monkeypatch)
    _data, directory = _work(tmp_path)
    (directory / "links.json").write_text(json.dumps([{"material_id": "m-link", "type": "repository", "url": "https://example.invalid/team/project.git"}]), encoding="utf-8")
    inventory = _run(directory, required=["repository"])
    _schema_check(inventory)
    link = next(m for m in inventory["materials"] if m["source"]["kind"] == "url")
    assert link["type"] == "repository" and link["status"] == "unavailable" and link["reason"]
    assert link["material_id"] == "m-link"
    assert inventory["completeness"]["missing"] == ["repository"] and inventory["completeness"]["status"] == "incomplete"
    assert "/Users/" not in json.dumps(inventory)


def test_private_link_is_blocked_without_request(tmp_path: Path) -> None:
    _data, directory = _work(tmp_path)
    (directory / "links.json").write_text(json.dumps([{"material_id": "m1", "type": "host", "url": "http://169.254.169.254/latest"}, {"material_id": "m2", "type": "repository", "url": "http://127.0.0.1/x.git"}]), encoding="utf-8")
    inventory = _run(directory)
    links = [m for m in inventory["materials"] if m["source"]["kind"] == "url"]
    assert len(links) == 2 and all(m["status"] == "unavailable" and m["reason"] for m in links)


def test_repository_link_is_cloned_and_git_log_written(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    origin = tmp_path / "origin"
    origin.mkdir()
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.org", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.org"}
    (origin / "app.py").write_text("x = 1\n", encoding="utf-8")
    for args in (["init", "-q", "-b", "main"], ["add", "."], ["commit", "-q", "-m", "c"]):
        subprocess.run(["git", *args], cwd=origin, env=env, check=True, capture_output=True)

    def fake_clone(source, destination):
        shutil.copytree(origin, destination)
        return Path(destination)

    monkeypatch.setattr(repo, "clone_repository", fake_clone)
    data, directory = _work(tmp_path)
    (directory / "links.json").write_text(json.dumps([{"material_id": "m-repo", "type": "repository", "url": "https://example.org/team/x.git"}]), encoding="utf-8")
    inventory = _run(directory, required=["repository"])
    _schema_check(inventory)
    material = next(m for m in inventory["materials"] if m["material_id"] == "m-repo")
    assert material["status"] == "available" and material["extracted"]["file_count"] == 1
    assert inventory["completeness"]["missing"] == []
    assert inventory["git"]["available"] is True and inventory["git"]["commit_count"] == 1
    assert (data / inventory["git"]["log_path"]).is_file()


def test_stage_failure_isolated_per_material(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    def boom(*args, **kwargs):
        raise RuntimeError("extractor exploded at /Users/someone/secret")

    monkeypatch.setattr(documents, "extract_document", boom)
    _data, directory = _work(tmp_path)
    inventory = _run(directory)
    _schema_check(inventory)
    readme = next(m for m in inventory["materials"] if m["source"]["path"].endswith("README.md"))
    assert readme["status"] in ("partial", "unavailable") and readme["reason"] and "/Users/" not in readme["reason"]
    assert next(m for m in inventory["materials"] if m["source"]["path"].endswith("main.py"))["status"] == "available"
    assert (directory / "inventory.json").is_file()


def test_archive_is_unpacked_and_evil_archive_is_unavailable(tmp_path: Path) -> None:
    _data, directory = _work(tmp_path, files={"README.md": "x"})
    with zipfile.ZipFile(directory / "good.zip", "w") as handle:
        handle.writestr("src/a.py", "print(1)\n")
    with zipfile.ZipFile(directory / "evil.zip", "w") as handle:
        handle.writestr("../../outside.txt", "escape")
    inventory = _run(directory)
    _schema_check(inventory)
    by_name = {Path(m["source"]["path"]).name: m for m in inventory["materials"]}
    assert by_name["good.zip"]["type"] == "archive" and by_name["good.zip"]["extracted"]["file_count"] == 1
    assert by_name["evil.zip"]["status"] == "unavailable" and by_name["evil.zip"]["reason"]
    assert not (tmp_path / "outside.txt").exists()


def test_secrets_in_extracted_text_are_masked_and_counted(tmp_path: Path) -> None:
    secret = "gh" + "p_" + "a" * 36
    data, directory = _work(tmp_path, files={"notes.md": f"token {secret}\n"})
    inventory = _run(directory)
    assert inventory["masked_secrets"] == 1
    text = (data / inventory["materials"][0]["extracted"]["text_path"]).read_text(encoding="utf-8")
    assert secret not in text
    assert (directory / "notes.md").read_text(encoding="utf-8").strip() == f"token {secret}"     # оригинал участника не трогаем


def test_similarity_json_written_for_project(tmp_path: Path) -> None:
    shared = "\n".join(f"v{i} = compute({i * 1009 + 311}) + {i * 503 + 607}" for i in range(60))
    data, first = _work(tmp_path, sid="s1", files={"main.py": shared})
    _d, second = _work(tmp_path, sid="s2", files={"app.py": shared})
    _work(tmp_path, sid="s3", files={"x.py": "\n".join(f"w{i} = other({i * 7919 + 13}) * {i * 104729 + 17}" for i in range(60))})
    _run(first)
    _run(second, submission_id="s2")
    doc = json.loads((data / "projects" / "p1" / "similarity.json").read_text(encoding="utf-8"))
    schema = json.loads((CONTRACTS / "similarity.schema.json").read_text(encoding="utf-8"))
    jsonschema.validate(doc, schema, format_checker=jsonschema.FormatChecker())
    assert any({p["submission_a"], p["submission_b"]} == {"s1", "s2"} for p in doc["pairs"])


def test_cli_accepts_backend_flags_and_legacy_call(tmp_path: Path) -> None:
    data, directory = _work(tmp_path)
    env = {"PATH": os.environ["PATH"], "PYTHONPATH": str(ROOT)}
    done = subprocess.run([sys.executable, "-m", "intake", str(directory), "--out", str(directory), "--project-id=p1", "--submission-id=s1", "--team-name=Команда", "--required=repository"], cwd=ROOT, env=env, capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    inventory = json.loads((directory / "inventory.json").read_text(encoding="utf-8"))
    _schema_check(inventory)
    assert inventory["team_name"] == "Команда" and inventory["completeness"]["missing"] == ["repository"]
    legacy = tmp_path / "legacy"
    legacy.mkdir()
    (legacy / "a.py").write_text("x = 1\n", encoding="utf-8")
    done = subprocess.run([sys.executable, "-m", "intake", str(legacy), "--out", str(tmp_path / "o")], cwd=ROOT, env=env, capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    assert (tmp_path / "o" / "inventory.json").is_file()


def test_fixture_corpus_passes_schema(tmp_path: Path) -> None:
    for name in ("good", "weak", "prompt-injection"):
        target = tmp_path / name
        shutil.copytree(FIXTURES / name, target)
        _schema_check(pipeline.run_pipeline(target, target, project_id="p", submission_id=name))
