"""browser.py — контракт и изоляция браузерных сессий роли 'design' (T003, T066 / R6).

Обеспечивает валидацию обязательных вьюпортов (1440x900 десктоп, 390x844 мобильный),
сбор и форматирование ошибок JS-консоли, строгую изоляцию артефактов скриншотов в
runs/<run_id>/browser/ и герметичность контекстов параллельных сессий.
"""
from __future__ import annotations

import logging
import os
import re
from typing import Any

try:
    from . import guard
except ImportError:
    import guard

log = logging.getLogger(__name__)

# Обязательные вьюпорты согласно PROJECT.md §8 и FR-017
SUPPORTED_VIEWPORTS = {
    (1440, 900),  # Desktop
    (390, 844),   # Mobile (iPhone 12/13/14 portrait)
}


def is_supported_viewport(width: int, height: int) -> bool:
    """Проверяет, соответствует ли вьюпорт поддерживаемым разрешениям."""
    if not isinstance(width, int) or not isinstance(height, int):
        return False
    return (width, height) in SUPPORTED_VIEWPORTS


def extract_console_errors(logs: list[dict[str, Any]] | None) -> list[str]:
    """Извлекает и форматирует ошибки консоли (console.error, unhandled exceptions)."""
    if not logs or not isinstance(logs, list):
        return []

    errors: list[str] = []
    for item in logs:
        if not isinstance(item, dict):
            continue
        log_type = str(item.get("type", "")).lower()
        text = str(item.get("text", "")).strip()

        if not text:
            continue

        if log_type in ("error", "exception", "failed") or "error" in text.lower():
            # Ограничиваем длину одной строкиhead+tail
            if len(text) > 1000:
                text = text[:500] + " ... [TRUNCATED] ... " + text[-500:]
            errors.append(text)

    return errors


def get_screenshot_destination(
    session_id: str | None,
    viewport: tuple[int, int],
    name: str = "screenshot",
) -> str:
    """Генерирует безопасный путь для скриншота внутри runs/<run_id>/browser/."""
    run_id = guard.extract_run_id(session_id) or "default"
    w, h = viewport

    # Санитизация имени файла
    clean_name = re.sub(r"[^a-zA-Z0-9_-]", "_", name).strip("_") or "screen"
    filename = f"{clean_name}_{w}x{h}.png"
    return f"runs/{run_id}/browser/{filename}"


class BrowserSessionContext:
    """Изолированный контекст браузерной сессии роли 'design'."""

    def __init__(self, session_id: str | None = None):
        self.session_id = session_id
        self.run_id = guard.extract_run_id(session_id) or "default"
        self._console_errors: list[str] = []
        self._screenshots: list[str] = []

    def record_console_error(self, message: str) -> None:
        """Добавляет ошибку консоли в изолированный буфер сессии."""
        if message and isinstance(message, str):
            self._console_errors.append(message)

    def record_screenshot(self, path: str) -> None:
        """Регистрирует созданный скриншот в буфере сессии."""
        if path and isinstance(path, str):
            self._screenshots.append(path)

    def get_errors(self) -> list[str]:
        return list(self._console_errors)

    def get_screenshots(self) -> list[str]:
        return list(self._screenshots)
