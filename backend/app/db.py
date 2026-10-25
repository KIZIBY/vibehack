"""Подключение к БД: движок, фабрика сессий, зависимость FastAPI."""
from contextlib import contextmanager
from typing import Annotated, Iterator

from fastapi import Depends, Request
from sqlalchemy import Engine, create_engine, event
from sqlalchemy.orm import Session, sessionmaker

BUSY_TIMEOUT_MS = 5000


def make_engine(url: str) -> Engine:
    """SQLite: внешние ключи включаются на КАЖДОМ соединении (PRAGMA действует на соединение, не на файл)."""
    if not url.startswith("sqlite"):
        return create_engine(url)
    engine = create_engine(url, connect_args={"check_same_thread": False, "timeout": BUSY_TIMEOUT_MS / 1000})

    @event.listens_for(engine, "connect")
    def _pragmas(dbapi_connection, _record):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.execute(f"PRAGMA busy_timeout={BUSY_TIMEOUT_MS}")
        cursor.close()

    return engine


def make_session_factory(engine: Engine) -> sessionmaker:
    return sessionmaker(bind=engine, expire_on_commit=False)


@contextmanager
def session_scope(factory: sessionmaker) -> Iterator[Session]:
    session = factory()
    try:
        yield session
        session.commit()
    except BaseException:
        session.rollback()
        raise
    finally:
        session.close()


def get_session(request: Request) -> Iterator[Session]:
    """Сессия запроса: commit при успехе, rollback при исключении. Подключай через SessionDep."""
    with session_scope(request.app.state.session_factory) as session:
        yield session


# scope="function": commit выполняется ДО отправки ответа клиенту. С областью по умолчанию FastAPI завершает
# зависимость после ответа, и сбой commit остался бы незамеченным при уже отданном 200.
SessionDep = Annotated[Session, Depends(get_session, scope="function")]
