"""guard.py — изоляция и защита ролей Hermes Agent (T001, T062 / R3, NFR-010).

Ограничивает доступные инструменты по роли (белый список), блокирует терминал и
опасные команды для роли 'code', блокирует попытки записи вне рабочего каталога runs/<run_id>/.
"""
from __future__ import annotations

import logging
import os
import re
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

# Белый список разрешённых инструментов для каждой роли
ROLE_ALLOWED_TOOLS: dict[str, set[str]] = {
    "code": {
        "read_file",
        "search_files",
        "file_structure",
        "list_directory",
        "judge_score",
        "report_scores",
        "report_flag",
        "report_claims",
    },
    "business": {
        "read_file",
        "search_files",
        "web_search",
        "delegate_task",
        "judge_score",
        "report_scores",
        "report_flag",
        "report_claims",
    },
    "design": {
        "read_file",
        "search_files",
        "browser_navigate",
        "browser_screenshot",
        "browser_console_logs",
        "judge_score",
        "report_scores",
        "report_flag",
        "report_claims",
        "report_ux_metrics",
    },
    "critic-uniqueness": {
        "read_file",
        "search_files",
        "web_search",
        "git_log",
        "judge_score",
        "report_scores",
        "report_flag",
        "report_claims",
    },
    "critic-honesty": {
        "read_file",
        "search_files",
        "judge_score",
        "report_scores",
        "report_flag",
        "report_claims",
    },
    "rubric": {
        "read_file",
        "search_files",
        "report_rubric",
    },
    "sorter": {
        "read_file",
        "search_files",
        "report_inventory_patch",
    },
}

KNOWN_ROLES = set(ROLE_ALLOWED_TOOLS.keys())

# Инструменты терминала/выполнения кода, запрещённые в роли судьи
BLOCKED_EXECUTION_TOOLS = {
    "terminal",
    "bash",
    "sh",
    "execute_command",
    "run_shell",
    "process_spawn",
    "exec",
}


def extract_role(session_id: str | None) -> str | None:
    """Извлекает имя роли из идентификатора сессии."""
    if not session_id or not isinstance(session_id, str):
        return None

    m = re.match(r"^role:([a-z0-9_-]+):?", session_id)
    if m:
        role = m.group(1).lower()
        if role in KNOWN_ROLES:
            return role

    for r in sorted(KNOWN_ROLES, key=len, reverse=True):
        if session_id == r or session_id.startswith(f"{r}:") or session_id.startswith(f"{r}-"):
            return r

    return None


def extract_run_id(session_id: str | None) -> str | None:
    """Извлекает run_id из session_id."""
    if not session_id or not isinstance(session_id, str):
        return None
    parts = session_id.split(":")
    if len(parts) >= 3 and parts[0] == "role":
        return parts[2]
    if len(parts) >= 2:
        return parts[1]
    return None


def check_cross_run_access(target_path: str, session_id: str | None) -> tuple[bool, str | None]:
    """Проверяет, что путь записи не пытается модифицировать чужой run_id."""
    run_id = extract_run_id(session_id)
    norm = target_path.replace("\\", "/")
    if run_id:
        m = re.search(r"runs/([^/]+)", norm)
        if m and m.group(1) != run_id:
            return False, f"Access denied: write outside runs/{run_id}/ (targeting чужой run '{m.group(1)}') is blocked"
    return True, None


def check_tool_call(
    tool_name: str,
    args: dict[str, Any] | None = None,
    session_id: str | None = None,
    **kwargs: Any,
) -> tuple[bool, str | None]:
    """Проверяет допустимость вызова инструмента для роли текущей сессии (Fail-Closed)."""
    del kwargs
    if not session_id:
        return False, "Access denied: missing session_id context"

    role = extract_role(session_id)
    if not role:
        return False, f"Access denied: unknown role or malformed session_id '{session_id}'"

    # 1. Проверка путей файлов и directory traversal в аргументах инструмента (приоритетная безопасность)
    if args and isinstance(args, dict):
        for key in ("path", "file_path", "filename", "destination", "output_path", "target"):
            val = args.get(key)
            if val and isinstance(val, str):
                is_write = tool_name.startswith("write_") or "save" in tool_name or key in ("destination", "output_path")
                ok, reason = check_file_access(val, session_id=session_id, is_write=is_write)
                if not ok:
                    return False, reason
                ok, reason = check_cross_run_access(val, session_id=session_id)
                if not ok:
                    return False, reason

    # 2. Проверка белого списка инструментов роли
    allowed = ROLE_ALLOWED_TOOLS.get(role, set())
    if tool_name not in allowed:
        return False, f"Access denied: tool '{tool_name}' is blocked for role '{role}'"

    return True, None


def check_file_access(
    file_path: str,
    session_id: str | None = None,
    is_write: bool = False,
    **kwargs: Any,
) -> tuple[bool, str | None]:
    """Запрещает запись вне runs/<run_id>/ и предотвращает traversal."""
    del kwargs
    if not file_path or not isinstance(file_path, str):
        return False, "Invalid file path"

    norm = os.path.normpath(file_path)
    if ".." in norm.split(os.sep):
        return False, "Access denied: directory traversal detected"

    if is_write:
        run_id = extract_run_id(session_id)
        normalized_str = norm.replace("\\", "/")
        if run_id:
            expected_prefix = f"runs/{run_id}"
            if expected_prefix not in normalized_str and not normalized_str.startswith(f"runs/{run_id}"):
                return False, f"Access denied: write outside runs/{run_id}/ is blocked"
        else:
            if "runs/" not in normalized_str:
                return False, "Access denied: write outside runs/ directory is blocked"

    return True, None


def pre_tool_call_guard(
    tool_name: str | None = None,
    args: dict[str, Any] | None = None,
    session_id: str | None = None,
    **kwargs: Any,
) -> bool:
    """Хук pre_tool_call для регистрации в плагине Hermes.

    Возвращает True если вызов разрешён, False если заблокирован.
    """
    if not tool_name:
        return False

    allowed, reason = check_tool_call(tool_name, args=args, session_id=session_id, **kwargs)
    if not allowed:
        log.warning("GUARD BLOCKED TOOL: %s (reason: %s)", tool_name, reason)
        return False
    return True
