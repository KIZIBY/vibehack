from __future__ import annotations

import json
import os
import subprocess
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


MAX_BYTES = 200 * 1024 * 1024
EXCLUDED_DIRS = {".git", "node_modules", "dist", "build", "__pycache__", ".venv"}
LANGUAGES = {".py": "Python", ".js": "JavaScript", ".jsx": "JavaScript", ".ts": "TypeScript", ".tsx": "TypeScript", ".java": "Java", ".go": "Go", ".rs": "Rust", ".rb": "Ruby", ".php": "PHP", ".c": "C", ".cpp": "C++", ".h": "C/C++"}


class RepositoryError(RuntimeError):
    pass


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True, env={**os.environ, "GIT_LFS_SKIP_SMUDGE": "1"})
    return result.stdout.strip()


def clone_repository(source: str, destination: str | Path) -> Path:
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    command = ["git", "-c", "core.hooksPath=/dev/null", "clone", "--no-recurse-submodules", source, str(destination)]
    try:
        subprocess.run(command, check=True, capture_output=True, text=True, env={**os.environ, "GIT_LFS_SKIP_SMUDGE": "1"})
    except subprocess.CalledProcessError as exc:
        raise RepositoryError(exc.stderr.strip() or "git clone failed") from exc
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
