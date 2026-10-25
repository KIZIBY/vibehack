"""Общие помощники: идентификаторы ULID и время в ISO-формате UTC."""
import os
import threading
import time
from datetime import datetime, timezone

_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"   # Crockford base32 без I, L, O, U
_lock = threading.Lock()
_last_ms = -1
_last_random = 0


def _encode(value: int, length: int) -> str:
    chars = []
    for _ in range(length):
        chars.append(_ALPHABET[value & 31])
        value >>= 5
    return "".join(reversed(chars))


def new_id() -> str:
    """ULID: 48 бит времени (мс) + 80 бит случайности; внутри одной миллисекунды случайная часть растёт на 1."""
    global _last_ms, _last_random
    with _lock:
        now_ms = int(time.time() * 1000)
        if now_ms > _last_ms:
            _last_ms, _last_random = now_ms, int.from_bytes(os.urandom(10), "big")
        else:
            _last_random += 1
            if _last_random >= 1 << 80:   # переполнение: берём следующую миллисекунду
                _last_ms, _last_random = _last_ms + 1, int.from_bytes(os.urandom(10), "big")
        return _encode(_last_ms, 10) + _encode(_last_random, 16)


def utc_now_iso() -> str:
    """Текущее время UTC строкой ISO-8601 с микросекундами: строки сортируются как время."""
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")
