"""Общие помощники репозиториев: оптимистичная запись по версии (I-15) и keyset-пагинация."""
import base64
import json
import re
from typing import Any, Optional

from sqlalchemy import text
from sqlalchemy.orm import Session

IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
MAX_PAGE = 200


class VersionConflict(Exception):
    """Строка изменилась с момента чтения: ожидаемая версия устарела."""


def _identifier(name: str) -> str:
    if not IDENTIFIER_RE.match(name):
        raise ValueError(f"недопустимое имя в SQL: {name!r}")
    return name


def update_versioned(session: Session, table: str, row_id: str, expected_version: int,
                     values: dict[str, Any], *, id_column: str = "id") -> int:
    """UPDATE … WHERE id = :id AND version = :expected; возвращает новую версию.

    Строки нет — LookupError, версия другая — VersionConflict. Значения всегда параметры запроса."""
    table, id_column = _identifier(table), _identifier(id_column)
    if not values or "version" in values or id_column in values:
        raise ValueError("values не должны быть пустыми и содержать version или ключ строки")
    assignments = ", ".join(f"{_identifier(col)} = :v_{col}" for col in values)
    params = {f"v_{col}": value for col, value in values.items()}
    params.update(row_id=row_id, expected=expected_version)
    result = session.execute(
        text(f"UPDATE {table} SET {assignments}, version = version + 1 "
             f"WHERE {id_column} = :row_id AND version = :expected"), params)
    if result.rowcount == 1:
        return expected_version + 1
    exists = session.execute(text(f"SELECT 1 FROM {table} WHERE {id_column} = :row_id"), {"row_id": row_id}).first()
    if exists is None:
        raise LookupError(f"{table}: строка {row_id!r} не найдена")
    raise VersionConflict(f"{table}: версия {expected_version} устарела")


def encode_cursor(created_at: str, row_id: str) -> str:
    raw = json.dumps([created_at, row_id], ensure_ascii=False, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode("ascii")


def decode_cursor(cursor: str) -> tuple[str, str]:
    try:
        data = json.loads(base64.urlsafe_b64decode(cursor.encode("ascii")))
    except (ValueError, UnicodeError, AttributeError):
        raise ValueError("некорректный курсор") from None
    if not (isinstance(data, list) and len(data) == 2 and all(isinstance(item, str) for item in data)):
        raise ValueError("некорректный курсор")
    return data[0], data[1]


def keyset_page(session: Session, table: str, *, limit: int, after: Optional[str] = None,
                where: Optional[str] = None, params: Optional[dict[str, Any]] = None,
                order_column: str = "created_at", id_column: str = "id"
                ) -> tuple[list[dict[str, Any]], Optional[str]]:
    """Страница по ключу (order_column, id) по возрастанию, без OFFSET; where — SQL с именованными параметрами."""
    table, order_column, id_column = _identifier(table), _identifier(order_column), _identifier(id_column)
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= MAX_PAGE:
        raise ValueError(f"limit должен быть от 1 до {MAX_PAGE}")
    conditions = [f"({where})"] if where else []
    bound = dict(params or {})
    if after is not None:
        position_time, position_id = decode_cursor(after)
        conditions.append(f"({order_column} > :_after_time OR ({order_column} = :_after_time AND {id_column} > :_after_id))")
        bound.update(_after_time=position_time, _after_id=position_id)
    clause = f"WHERE {' AND '.join(conditions)} " if conditions else ""
    bound["_limit"] = limit + 1
    rows = [dict(row) for row in session.execute(
        text(f"SELECT * FROM {table} {clause}ORDER BY {order_column}, {id_column} LIMIT :_limit"), bound).mappings()]
    page = rows[:limit]
    next_cursor = encode_cursor(str(page[-1][order_column]), str(page[-1][id_column])) if len(rows) > limit else None
    return page, next_cursor
