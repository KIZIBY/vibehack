from __future__ import annotations

import mimetypes
import re
from pathlib import Path, PurePath
from urllib.parse import urlparse


EXTENSIONS = {
    ".pdf": "document", ".doc": "document", ".docx": "document", ".ppt": "presentation", ".pptx": "presentation",
    ".csv": "metrics_row", ".xlsx": "metrics_row", ".xls": "metrics_row", ".md": "document", ".txt": "document",
    ".png": "image", ".jpg": "image", ".jpeg": "image", ".webp": "image", ".gif": "image",
    ".mp4": "screencast", ".mov": "screencast", ".webm": "screencast", ".wav": "screencast", ".mp3": "screencast",
    ".zip": "archive", ".tar": "archive", ".gz": "archive", ".7z": "archive",
    ".py": "code_file", ".js": "code_file", ".ts": "code_file", ".tsx": "code_file", ".java": "code_file", ".go": "code_file", ".rs": "code_file",
}
URL_TYPES = {"github.com": "repository", "gitlab.com": "repository", "bitbucket.org": "repository"}


def _signature(path: Path) -> str | None:
    try:
        header = path.read_bytes()[:16]
    except OSError:
        return None
    if header.startswith(b"%PDF"):
        return "document"
    if header.startswith(b"PK\x03\x04"):
        return "archive"
    if header.startswith(b"\x1f\x8b"):
        return "archive"
    if header.startswith(b"\x89PNG") or header.startswith(b"\xff\xd8\xff"):
        return "image"
    return None


def classify_path(path: str | Path, relative: str | None = None) -> str:
    path = Path(path)
    signature = _signature(path) if path.is_file() else None
    if signature == "archive" and path.suffix.lower() in {".docx", ".pptx", ".xlsx"}:
        return EXTENSIONS[path.suffix.lower()]
    if signature:
        return signature
    if path.is_dir() or (relative and ".git" in PurePath(relative).parts):
        return "repository"
    return EXTENSIONS.get(path.suffix.lower(), "other")


def classify_url(url: str) -> str:
    host = (urlparse(url).hostname or "").lower()
    if host in URL_TYPES or host.startswith("raw."):
        return "repository"
    suffix = Path(urlparse(url).path).suffix.lower()
    return EXTENSIONS.get(suffix, "host")


def team_from_path(relative: str) -> str | None:
    parts = [part for part in PurePath(relative).parts if part not in {".", ""}]
    return parts[0] if len(parts) > 1 else None


def team_from_url(url: str) -> str | None:
    parsed = urlparse(url)
    path = [part for part in parsed.path.split("/") if part]
    if parsed.hostname and parsed.hostname.lower() in URL_TYPES and len(path) >= 2:
        return path[1] if path[0] else path[0]
    match = re.search(r"(?:team|team_name)=([^&]+)", parsed.query, re.IGNORECASE)
    return match.group(1) if match else None


def classify(path: str | Path, *, relative: str | None = None, url: str | None = None) -> dict[str, str | None]:
    if url:
        return {"type": classify_url(url), "team": team_from_url(url), "mime": mimetypes.guess_type(url)[0]}
    return {"type": classify_path(path, relative), "team": team_from_path(relative or str(path)), "mime": mimetypes.guess_type(str(path))[0]}
