"""Runs migrations against REVIVE_DATABASE_URL with the synchronous psycopg driver."""

import os

from alembic import context
from sqlalchemy import create_engine

from revive_api.models import Base

target_metadata = Base.metadata


def run() -> None:
    url = os.environ.get("REVIVE_DATABASE_URL")
    if not url:
        raise SystemExit("set REVIVE_DATABASE_URL (postgresql+psycopg://...)")
    if context.is_offline_mode():
        context.configure(url=url, target_metadata=target_metadata, literal_binds=True)
        with context.begin_transaction():
            context.run_migrations()
        return
    engine = create_engine(url)
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()
    engine.dispose()


run()
