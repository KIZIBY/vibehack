"""Настройки приложения из окружения (имена переменных — .env.example)."""
import os
import re
from dataclasses import dataclass, fields
from typing import Mapping, Optional

MASKED = "***"
SECRET_FIELDS = frozenset({"demo_password", "session_secret", "api_server_key"})
URL_FIELDS = frozenset({"database_url", "hermes_api_url"})
URL_PASSWORD_RE = re.compile(r"(?<=:" + r"//)([^/@:\s]*):([^@/\s]*)@")   # логин:пароль@ в адресе


def mask_url_password(value: str) -> str:
    """Прячет пароль в части «логин:пароль@» адреса (само поле хранит полный URL)."""
    return URL_PASSWORD_RE.sub(lambda m: f"{m.group(1)}:{MASKED}@", value)


@dataclass(frozen=True)
class Settings:
    database_url: str = "sqlite:///judge.db"
    data_dir: str = "./data"
    hermes_api_url: Optional[str] = None
    api_server_key: Optional[str] = None
    max_parallel_submissions: int = 5
    retention_days: int = 7
    demo_user: Optional[str] = None
    demo_password: Optional[str] = None
    session_secret: Optional[str] = None
    version: str = "dev"
    log_level: str = "INFO"
    cookie_secure: bool = False

    def __repr__(self) -> str:
        parts = []
        for f in fields(self):
            value = getattr(self, f.name)
            if f.name in SECRET_FIELDS and value is not None:
                shown = MASKED
            elif f.name in URL_FIELDS and value is not None:
                shown = repr(mask_url_password(value))
            else:
                shown = repr(value)
            parts.append(f"{f.name}={shown}")
        return f"Settings({', '.join(parts)})"

    __str__ = __repr__


def _text(env: Mapping[str, str], name: str, default: Optional[str]) -> Optional[str]:
    value = env.get(name)
    return default if value is None or value == "" else value


def _integer(env: Mapping[str, str], name: str, default: int) -> int:
    value = _text(env, name, None)
    if value is None:
        return default
    try:
        return int(value)
    except ValueError:
        raise ValueError(f"{name}: ожидается целое число, получено {value!r}") from None


def _boolean(env: Mapping[str, str], name: str, default: bool) -> bool:
    value = _text(env, name, None)
    return default if value is None else value.strip().lower() in ("true", "1", "yes")


def load_settings(env: Optional[Mapping[str, str]] = None) -> Settings:
    """Пустая строка в переменной = не задана. Нецелое значение числовой переменной — ValueError с её именем."""
    env = os.environ if env is None else env
    return Settings(
        database_url=_text(env, "JUDGE_DATABASE_URL", Settings.database_url),
        data_dir=_text(env, "JUDGE_DATA_DIR", Settings.data_dir),
        hermes_api_url=_text(env, "HERMES_API_URL", None),
        api_server_key=_text(env, "API_SERVER_KEY", None),
        max_parallel_submissions=_integer(env, "JUDGE_MAX_PARALLEL_SUBMISSIONS", Settings.max_parallel_submissions),
        retention_days=_integer(env, "JUDGE_RETENTION_DAYS", Settings.retention_days),
        demo_user=_text(env, "JUDGE_DEMO_USER", None),
        demo_password=_text(env, "JUDGE_DEMO_PASSWORD", None),
        session_secret=_text(env, "JUDGE_SESSION_SECRET", None),
        version=_text(env, "JUDGE_VERSION", Settings.version),
        log_level=_text(env, "JUDGE_LOG_LEVEL", Settings.log_level),
        cookie_secure=_boolean(env, "JUDGE_COOKIE_SECURE", Settings.cookie_secure),
    )
