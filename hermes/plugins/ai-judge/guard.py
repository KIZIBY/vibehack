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
        "report_scores",
        "report_flag",
        "report_claims",
    },
    "business": {
        "read_file",
        "search_files",
        "web_search",
        "delegate_task",
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
        "report_scores",
        "report_flag",
        "report_claims",
    },
    "critic-honesty": {
        "read_file",
        "search_files",
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
    """Извлекает имя роли из идентификатора сессии.

    Форматы:
    - 'role:<role>:<run_id>' (например 'role:code:sub_123')
    - '<role>:<run_id>'      (например 'code:sub_456')
    - '<role>-<run_id>'      (например 'code-sub_789')
    """
    if not session_id or not isinstance(session_id, str):
        return None

    # role:<role>:<run_id>
    m = re.match(r"^role:([a-z0-9_-]+):?", session_id)
    if m:
        role = m.group(1).lower()
        if role in KNOWN_ROLES:
            return role

    # <role>:<run_id> or <role>-<run_id>
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

    allowed = ROLE_ALLOWED_TOOLS.get(role, set())
    if tool_name not in allowed:
        return False, f"Access denied: tool '{tool_name}' is blocked for role '{role}'"

    # Дополнительная проверка путей файлов в аргументах инструмента
    if args and isinstance(args, dict):
        path = args.get("path") or args.get("file_path") or args.get("filename")
        if path and isinstance(path, str):
            is_write = tool_name.startswith("write_") or "save" in tool_name
            ok, reason = check_file_access(path, session_id=session_id, is_write=is_write)
            if not ok:
                return False, reason

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

    # Предотвращение directory traversal
    norm = os.path.normpath(file_path)
    if ".." in norm.split(os.sep):
        return False, "Access denied: directory traversal detected"

    if is_write:
        run_id = extract_run_id(session_id)
        # Запись разрешена только внутри каталога runs/<run_id>/
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
