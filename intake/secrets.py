from __future__ import annotations

import re
from pathlib import Path

PATTERNS = (
    re.compile(r"-----BEGIN [A-Z0-9 ]+ PRIVATE KEY-----.*?-----END [A-Z0-9 ]+ PRIVATE KEY-----", re.DOTALL),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\b(?:sk-live-|sk-proj-|sk-ant-api03-|sk-ant-admin01-)[A-Za-z0-9_-]{12,}\b"),
    re.compile(r"\bghp_[A-Za-z0-9]{20,}\b"),
    re.compile(r"(https?://)([^\s:/]+):([^\s@]+)@", re.IGNORECASE),
)


def mask_secrets(text: str) -> tuple[str, int]:
    count = 0

    def replace(match: re.Match[str]) -> str:
        nonlocal count
        count += 1
        if match.lastindex == 3 and match.group(1):
            return f"{match.group(1)}[REDACTED]:[REDACTED]@"
        return "[REDACTED]"

    for pattern in PATTERNS:
        text = pattern.sub(replace, text)
    return text, count


def mask_file(source: str | Path, destination: str | Path | None = None) -> int:
    source, destination = Path(source), Path(destination) if destination else Path(source)
    masked, count = mask_secrets(source.read_text(encoding="utf-8", errors="replace"))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(masked, encoding="utf-8")
    return count
