"""Окружение Alembic: URL берётся из конфигурации, затем из JUDGE_DATABASE_URL, затем judge.db в текущем каталоге."""
import os

from alembic import context
from sqlalchemy import create_engine, pool

DEFAULT_URL = "sqlite:///judge.db"

config = context.config
url = config.get_main_option("sqlalchemy.url") or os.environ.get("JUDGE_DATABASE_URL") or DEFAULT_URL

if context.is_offline_mode():
    context.configure(url=url, literal_binds=True, dialect_opts={"paramstyle": "named"})
    with context.begin_transaction():
        context.run_migrations()
else:
    engine = create_engine(url, poolclass=pool.NullPool)
    with engine.connect() as connection:
        context.configure(connection=connection)
        with context.begin_transaction():
            context.run_migrations()
