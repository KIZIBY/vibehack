from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

import pytest

from intake import repo, secrets


def _src(path: Path) -> Path:
    path.mkdir(parents=True)
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.org", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.org"}
    for args in (["init", "-q", "-b", "main"], ["add", "."], ["commit", "-q", "--allow-empty", "-m", "c"]):
        subprocess.run(["git", *args], cwd=path, env=env, check=True, capture_output=True)
    return path


def test_failed_clone_never_deletes_existing_destination(tmp_path: Path) -> None:
    src = _src(tmp_path / "src")
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "previous.txt").write_text("keep", encoding="utf-8")
    with pytest.raises(repo.RepositoryError):
        repo.clone_repository(str(src), dest)
    assert (dest / "previous.txt").read_text(encoding="utf-8") == "keep"


def test_bad_port_in_url_is_repository_error(tmp_path: Path) -> None:
    with pytest.raises(repo.RepositoryError):
        repo.clone_repository("https://example.org:99999/x.git", tmp_path / "d")


def test_url_credentials_pattern_is_linear() -> None:
    started = time.monotonic()
    secrets.mask_secrets("http://a:" * 50_000)
    assert time.monotonic() - started < 3
