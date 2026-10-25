from __future__ import annotations

import re
from pathlib import Path

PATTERNS = (
    re.compile(r"-----BEGIN [A-Z0-9 ]{1,40} PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]{1,40} PRIVATE KEY-----|\Z)", re.DOTALL),
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


_BYTE_PATTERNS = tuple(re.compile(pattern.pattern.encode("utf-8"), pattern.flags & ~re.UNICODE) for pattern in PATTERNS)


def mask_bytes(raw: bytes) -> tuple[bytes, int]:
    """Маскирование на уровне байтов: остальное содержимое (в т.ч. не UTF-8) не искажается."""
    count = 0

    def replace(match: re.Match[bytes]) -> bytes:
        nonlocal count
        count += 1
        if match.lastindex == 3 and match.group(1):
            return match.group(1) + b"[REDACTED]:[REDACTED]@"
        return b"[REDACTED]"

    for pattern in _BYTE_PATTERNS:
        raw = pattern.sub(replace, raw)
    return raw, count


def mask_file(source: str | Path, destination: str | Path | None = None) -> int:
    source, destination = Path(source), Path(destination) if destination else Path(source)
    masked, count = mask_bytes(source.read_bytes())
    if count or destination != source:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(masked)
    return count
