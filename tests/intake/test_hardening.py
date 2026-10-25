from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest

from intake import repo, secrets, video


def _git(cwd: Path, *args: str) -> None:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.org", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.org"}
    subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True)


def _make_repo(path: Path) -> Path:
    path.mkdir(parents=True)
    _git(path, "init", "-q", "-b", "main")
    (path / "a.py").write_text("print(1)\n", encoding="utf-8")
    _git(path, "add", ".")
    _git(path, "commit", "-q", "-m", "c0")
    return path


def test_clone_does_not_materialize_symlinks(tmp_path: Path) -> None:
    src = _make_repo(tmp_path / "src")
    outside = tmp_path / "outside"
    outside.mkdir()
    os.symlink(outside, src / "linkdir")
    os.symlink(outside / "k", src / "linkfile")
    _git(src, "add", ".")
    _git(src, "commit", "-q", "-m", "links")
    dest = repo.clone_repository(str(src), tmp_path / "dest")
    assert [p for p in dest.rglob("*") if p.is_symlink()] == []


def test_clone_rejects_git_file_and_alternates(tmp_path: Path) -> None:
    real = _make_repo(tmp_path / "real")
    fake = tmp_path / "fake"
    fake.mkdir()
    (fake / ".git").write_text(f"gitdir: {real / '.git'}\n", encoding="utf-8")
    with pytest.raises(repo.RepositoryError):
        repo.clone_repository(str(fake), tmp_path / "d1")
    src = _make_repo(tmp_path / "src")
    info = src / ".git" / "objects" / "info"
    info.mkdir(parents=True, exist_ok=True)
    (info / "alternates").write_text(f"{real / '.git' / 'objects'}\n", encoding="utf-8")
    with pytest.raises(repo.RepositoryError):
        repo.clone_repository(str(src), tmp_path / "d2")


def test_clone_by_url_checks_address_and_pins_dns(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[list[str]] = []

    def fake_run(cmd, *args, **kwargs):
        calls.append(list(cmd))
        raise subprocess.CalledProcessError(1, cmd, stderr="stop")

    monkeypatch.setattr(subprocess, "run", fake_run)
    real_popen = subprocess.Popen

    def fake_popen(cmd, *args, **kwargs):
        calls.append(list(cmd))
        return real_popen([sys.executable, "-c", "import sys; sys.exit(1)"], *args, **kwargs)

    monkeypatch.setattr(subprocess, "Popen", fake_popen)
    for bad in ("http://127.0.0.1/x.git", "https://169.254.169.254/x.git", "ext::sh -c id", "file:///etc"):
        with pytest.raises(repo.RepositoryError):
            repo.clone_repository(bad, tmp_path / "d")
    assert calls == []
    monkeypatch.setattr(socket, "getaddrinfo", lambda host, port, **kw: [(2, 1, 6, "", ("93.184.216.34", port))])
    with pytest.raises(repo.RepositoryError):
        repo.clone_repository("https://example.org/team/x.git", tmp_path / "d")
    flat = " ".join(" ".join(c) for c in calls)
    assert "http.curloptResolve=example.org:443:93.184.216.34" in flat
    assert "http.followRedirects=false" in flat


def test_clone_runs_in_own_process_group(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict = {}
    real = subprocess.Popen

    def spy(*args, **kwargs):
        captured.update(kwargs)
        return real(*args, **kwargs)

    monkeypatch.setattr(subprocess, "Popen", spy)
    src = _make_repo(tmp_path / "src")
    repo.clone_repository(str(src), tmp_path / "dest")
    assert captured.get("start_new_session") is True


def test_running_command_is_killed_when_disk_cap_exceeded(tmp_path: Path) -> None:
    code = "import os,sys,time\nfor i in range(200):\n    open(os.path.join(sys.argv[1],str(i)),'wb').write(b'0'*100000)\n    time.sleep(0.05)\n"
    with pytest.raises(repo.RepositoryError, match="лимит|limit"):
        repo._run_limited([sys.executable, "-c", code, str(tmp_path)], watch=tmp_path, cap=300_000, timeout=30)
    assert len(list(tmp_path.iterdir())) < 100


def test_ffmpeg_and_ffprobe_get_protocol_whitelist(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[list[str]] = []

    def fake_run(cmd):
        calls.append(list(cmd))
        return subprocess.CompletedProcess(cmd, 0, "10\n", "")

    monkeypatch.setattr(video, "_run", fake_run)
    monkeypatch.setattr(video.shutil, "which", lambda name: "/usr/bin/" + name)
    clip = tmp_path / "demo.mp4"
    clip.write_bytes(b"#EXTM3U\nhttp://169.254.169.254/x.ts\n")
    video.extract_video(clip, tmp_path / "out")
    assert len(calls) >= 3
    for cmd in calls:
        assert "-protocol_whitelist" in cmd and cmd[cmd.index("-protocol_whitelist") + 1] == "file"
        assert cmd.index("-protocol_whitelist") < cmd.index("-i") if "-i" in cmd else True


def test_unclosed_private_key_headers_do_not_hang_masking() -> None:
    started = time.monotonic()
    secrets.mask_secrets("-----BEGIN A PRIVATE KEY-----\n" * 20_000)
    secrets.mask_secrets("a" * 200_000)
    assert time.monotonic() - started < 3


def test_mask_file_keeps_non_utf8_bytes_and_untouched_files(tmp_path: Path) -> None:
    clean = tmp_path / "clean.txt"
    clean.write_bytes(b"caf\xe9 \xff end")
    assert secrets.mask_file(clean) == 0
    assert clean.read_bytes() == b"caf\xe9 \xff end"
    secret = "gh" + "p_" + "a" * 36
    dirty = tmp_path / "dirty.txt"
    dirty.write_bytes(b"caf\xe9 " + secret.encode() + b" \xff end")
    assert secrets.mask_file(dirty) == 1
    data = dirty.read_bytes()
    assert b"caf\xe9 " in data and b" \xff end" in data and secret.encode() not in data
