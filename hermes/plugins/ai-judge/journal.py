"""
hermes/plugins/ai-judge/journal.py — Хуки логирования событий в journal.jsonl (T061).
Соответствует specs/001-ai-judge-platform/contracts/journal-event.schema.json (FR-029, NFR-008, NFR-012).
"""

import os
import re
import json
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

try:
    from . import guard
except (ImportError, ValueError):
    import guard

_JOURNAL_LOCK = threading.RLock()

# Patterns for secret masking (NFR-012)
SECRET_PATTERNS = [
    (re.compile(r"sk-[a-zA-Z0-9_\-]{16,}", re.IGNORECASE), "[MASKED]"),
    (re.compile(r"gh[pousr][_-][a-zA-Z0-9]{20,}", re.IGNORECASE), "[MASKED]"),
    (re.compile(r"Bearer\s+[a-zA-Z0-9_\-\.]{15,}", re.IGNORECASE), "Bearer [MASKED]"),
    (re.compile(r'(?i)(["\']?(?:password|token|secret|api_key|private_key)["\']?\s*[:=]\s*["\'])([^"\',\s]+)(["\']?)'), r'\1[MASKED]\3'),
]


def mask_secrets(text: str) -> str:
    """Mask credentials and secrets in text strings."""
    if not isinstance(text, str):
        return text
    result = text
    for pattern, replacement in SECRET_PATTERNS:
        result = pattern.sub(replacement, result)
    return result


def _truncate_and_mask(obj: Any, max_len: int = 2000) -> Optional[str]:
    """Serialize object to JSON, mask secrets, and truncate to max_len."""
    if obj is None:
        return None
    try:
        raw_str = json.dumps(obj, ensure_ascii=False)
    except Exception:
        raw_str = str(obj)
    masked = mask_secrets(raw_str)
    if len(masked) > max_len:
        return masked[: max_len - 3] + "..."
    return masked


def _get_data_root() -> Path:
    data_dir_env = os.environ.get("JUDGE_DATA_DIR")
    if data_dir_env:
        return Path(data_dir_env)
    return Path(__file__).resolve().parent.parent.parent.parent


def append_journal_event(event_dict: Dict[str, Any]) -> None:
    """
    Append an event to runs/<run_id>/journal.jsonl in a thread-safe, sequential manner.
    """
    run_id = event_dict.get("run_id")
    if not isinstance(run_id, str) or not guard._SAFE_ID.match(run_id) or ".." in run_id:
        return  # небезопасный run_id никогда не становится частью пути

    data_root = _get_data_root()
    run_dir = data_root / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    journal_path = run_dir / "journal.jsonl"

    with _JOURNAL_LOCK:
        current_seq = 0
        if journal_path.exists():
            try:
                content = journal_path.read_text(encoding="utf-8").strip()
                if content:
                    lines = content.splitlines()
                    current_seq = len(lines)
            except Exception:
                current_seq = 0

        event_dict["seq"] = current_seq

        line = json.dumps(event_dict, ensure_ascii=False)
        with open(journal_path, "a", encoding="utf-8") as f:
            f.write(line + "\n")


def post_tool_call(
    session_id: str,
    tool: str,
    args: Optional[Dict[str, Any]] = None,
    result: Optional[Any] = None,
    duration_ms: Optional[int] = None,
    project_id: str = "default",
    submission_id: Optional[str] = None,
    refs: Optional[List[str]] = None,
) -> None:
    """
    Hook called after a tool execution. Appends event to journal.jsonl.
    """
    parsed = guard.parse_session_id(session_id) or {}
    run_id = parsed.get("run_id") or (session_id.split(":")[0] if session_id else None)
    role = parsed.get("role")
    if submission_id is None and parsed.get("scope") not in (None, guard.PROJECT_SCOPE):
        submission_id = parsed["scope"]

    # Map special tool calls to specific event types
    event_name = "tool_call"
    if tool == "report_scores":
        event_name = "score_reported"
    elif tool == "report_flag":
        event_name = "flag_reported"
    elif tool == "report_claims":
        event_name = "claims_reported"
    elif tool == "report_rubric":
        event_name = "score_reported"

    event_payload = {
        "schema_version": "1",
        "ts": datetime.now(timezone.utc).isoformat(),
        "project_id": project_id,
        "run_id": run_id,
        "submission_id": submission_id,
        "role": role,
        "session_id": session_id,
        "event": event_name,
        "tool": tool,
        "args_summary": _truncate_and_mask(args),
        "result_summary": _truncate_and_mask(result),
        "refs": refs or [],
        "duration_ms": duration_ms,
        "source": "hermes.post_tool_call",
    }

    append_journal_event(event_payload)


def post_llm_call(
    session_id: str,
    model: Optional[str] = None,
    provider: Optional[str] = None,
    duration_ms: Optional[int] = None,
    project_id: str = "default",
    submission_id: Optional[str] = None,
    tokens_in: Optional[int] = None,
    tokens_out: Optional[int] = None,
    cost_usd: Optional[float] = None,
) -> None:
    """
    Hook called after an LLM generation. Appends model_call event to journal.jsonl.
    Leaves tokens and cost as null if no provider metrics available (NFR-008).
    """
    parsed = guard.parse_session_id(session_id) or {}
    run_id = parsed.get("run_id") or (session_id.split(":")[0] if session_id else None)
    role = parsed.get("role")
    if submission_id is None and parsed.get("scope") not in (None, guard.PROJECT_SCOPE):
        submission_id = parsed["scope"]

    event_payload = {
        "schema_version": "1",
        "ts": datetime.now(timezone.utc).isoformat(),
        "project_id": project_id,
        "run_id": run_id,
        "submission_id": submission_id,
        "role": role,
        "session_id": session_id,
        "event": "model_call",
        "tool": None,
        "args_summary": None,
        "result_summary": None,
        "refs": [],
        "duration_ms": duration_ms,
        "model": model,
        "provider": provider,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
        "cost_usd": cost_usd,
        "source": "hermes.post_llm_call",
    }

    append_journal_event(event_payload)
