"""Подсчёт итога: тонкий загрузчик ``compute_score`` из плагина ``hermes/plugins/ai-judge/tools.py``.

Итог команды считает ровно один код (устав I-4, FR-021): та же функция, что стоит за инструментом
``judge_score``. Копии формулы в backend нет — модуль плагина подгружается по пути от этого файла.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
from typing import Callable

TOOLS_PATH = Path(__file__).resolve().parents[2] / "hermes" / "plugins" / "ai-judge" / "tools.py"
_MODULE_NAME = "ai_judge_plugin_tools"


def load_compute_score(path: Path | str = TOOLS_PATH) -> Callable[[list], dict]:
    """Загружает ``compute_score`` из файла плагина, не регистрируя модуль в ``sys.modules``."""
    path = Path(path)
    if not path.is_file():
        raise FileNotFoundError(f"Файл плагина ai-judge с compute_score не найден: {path}")
    spec = importlib.util.spec_from_file_location(_MODULE_NAME, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Не удалось загрузить плагин ai-judge из {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    func = getattr(module, "compute_score", None)
    if not callable(func):
        raise ImportError(f"В {path} нет функции compute_score")
    return func


compute_score = load_compute_score()
