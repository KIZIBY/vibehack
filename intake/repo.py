from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

from . import web


MAX_BYTES = 200 * 1024 * 1024
EXCLUDED_DIRS = {".git", "node_modules", "dist", "build", "__pycache__", ".venv"}
LANGUAGES = {".py": "Python", ".js": "JavaScript", ".jsx": "JavaScript", ".ts": "TypeScript", ".tsx": "TypeScript", ".java": "Java", ".go": "Go", ".rs": "Rust", ".rb": "Ruby", ".php": "PHP", ".c": "C", ".cpp": "C++", ".h": "C/C++"}


class RepositoryError(RuntimeError):
    pass


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True, env={**os.environ, "GIT_LFS_SKIP_SMUDGE": "1"})
    return result.stdout.strip()


HARD_CAP_FACTOR = 10  # клон, выросший больше чем в 10 раз сверх лимита, обрывается
CLONE_TIMEOUT = 180


def _dir_size(path: Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def _safe_reason(text: str) -> str:
    return re.sub(r"(?:[A-Za-z]:)?(?:/[^\s'\"]+){2,}", "<путь>", text or "").strip()[:200]


def _run_limited(cmd: list[str], *, watch: Path | None = None, cap: int | None = None, timeout: int = CLONE_TIMEOUT) -> None:
    """Запуск в своей группе процессов: по таймауту или росту каталога выше cap убивается вся группа."""
    proc = subprocess.Popen(cmd, env={**os.environ, "GIT_LFS_SKIP_SMUDGE": "1", "GIT_TERMINAL_PROMPT": "0"}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, start_new_session=True)
    deadline = time.monotonic() + timeout

    def kill() -> None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            proc.kill()
        proc.communicate()

    while True:
        try:
            _out, err = proc.communicate(timeout=0.2)
            break
        except subprocess.TimeoutExpired:
            if time.monotonic() > deadline:
                kill()
                raise RepositoryError("превышено время клонирования") from None
            if watch is not None and cap is not None and _dir_size(watch) > cap:
                kill()
                raise RepositoryError("клонирование остановлено: превышен лимит диска") from None
    if proc.returncode != 0:
        lines = (err or b"").decode("utf-8", errors="replace").strip().splitlines()
        raise RepositoryError(_safe_reason(lines[-1]) if lines else "git clone failed")


def _strip_symlinks(root: Path) -> None:
    for current, dirs, files in os.walk(root):
        for name in list(dirs):
            full = Path(current) / name
            if full.is_symlink():
                full.unlink(missing_ok=True)
                dirs.remove(name)
        for name in files:
            full = Path(current) / name
            if full.is_symlink():
                full.unlink(missing_ok=True)


def _check_local_source(path: Path) -> None:
    git_dir = path / ".git"
    if git_dir.is_symlink() or not git_dir.is_dir():
        raise RepositoryError("репозиторий недоступен: нет собственного каталога .git")
    if (git_dir / "objects" / "info" / "alternates").exists() or (git_dir / "commondir").exists():
        raise RepositoryError("репозиторий недоступен: ссылается на чужие объекты")


def clone_repository(source: str, destination: str | Path) -> Path:
    """Клон каталога или публичного http(s)-URL без хуков, сабмодулей, LFS и симлинков."""
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    safe = ["-c", "core.hooksPath=/dev/null", "-c", "core.symlinks=false", "-c", "core.fsmonitor=false", "-c", "filter.lfs.smudge=", "-c", "filter.lfs.process=", "-c", "filter.lfs.required=false", "-c", "protocol.ext.allow=never"]
    if "://" in source or source.startswith("ext::"):
        try:
            addresses = web._public_host(source)
        except (web.SSRFBlocked, web.FetchFailed) as exc:
            raise RepositoryError(f"ссылка отклонена: {exc}") from exc
        parsed = urlsplit(source)
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        safe += ["-c", f"http.curloptResolve={parsed.hostname}:{port}:{addresses[0]}", "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=30",
                 "-c", "protocol.allow=never", "-c", "protocol.https.allow=always", "-c", "protocol.http.allow=always", "-c", "http.followRedirects=false"]
        extra: list[str] = []
    else:
        _check_local_source(Path(source))
        extra = ["--no-local", "--no-hardlinks"]
    command = ["git", *safe, "clone", "--quiet", "--no-recurse-submodules", *extra, "--", source, str(destination)]
    try:
        _run_limited(command, watch=destination, cap=MAX_BYTES * HARD_CAP_FACTOR)
    except RepositoryError:
        shutil.rmtree(destination, ignore_errors=True)
        raise
    _strip_symlinks(destination)
    return destination


def inspect_repository(repo: str | Path, output: str | Path, *, start_at: str | None = None) -> dict:
    repo, output = Path(repo), Path(output)
    if not (repo / ".git").exists():
        raise RepositoryError(f"not a git repository: {repo}")
    output.mkdir(parents=True, exist_ok=True)
    files: list[dict[str, object]] = []
    total_bytes = 0
    language_counts: Counter[str] = Counter()
    for path in sorted(repo.rglob("*")):
        if not path.is_file() or any(part in EXCLUDED_DIRS for part in path.relative_to(repo).parts):
            continue
        relative = path.relative_to(repo).as_posix()
        size = path.stat().st_size
        total_bytes += size
        if path.suffix.lower() in LANGUAGES:
            language_counts[LANGUAGES[path.suffix.lower()]] += 1
        files.append({"path": relative, "size_bytes": size})
    commits = _git(repo, "log", "--format=%H%x09%aI%x09%s").splitlines()
    first, last = (commits[-1].split("\t", 2) if commits else [None, None, None]), (commits[0].split("\t", 2) if commits else [None, None, None])
    before = _git(repo, "rev-list", "--count", "--all", "--before", start_at).strip() if start_at else "0"
    log = {"first_commit": first[0], "first_commit_at": first[1], "last_commit": last[0], "last_commit_at": last[1], "commit_count": len(commits), "commits_before_start": int(before or 0), "history_rewritten": False, "commits": [line.split("\t", 2) for line in commits]}
    (output / "git_log.json").write_text(json.dumps(log, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return {"available": True, "repo_dir": str(repo), "file_count": len(files), "total_bytes": total_bytes, "truncated": total_bytes > MAX_BYTES, "languages": dict(language_counts), "files": files, "git_log_path": (output / "git_log.json").as_posix(), "first_commit_at": first[1], "last_commit_at": last[1], "commit_count": len(commits), "commits_before_start": int(before or 0), "history_rewritten": False, "measured_at": datetime.now(timezone.utc).isoformat()}
