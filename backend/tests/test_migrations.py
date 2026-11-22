"""The migrations describe exactly the models, and go down and up again cleanly."""

import os

from alembic import command
from alembic.config import Config
from conftest import BACKEND, TEST_URL
from sqlalchemy import create_engine, inspect


def _config() -> Config:
    config = Config(str(BACKEND / "alembic.ini"))
    config.set_main_option("script_location", str(BACKEND / "migrations"))
    os.environ["REVIVE_DATABASE_URL"] = TEST_URL
    return config


def test_models_and_migrations_agree():
    # Raises if autogenerate would produce a new migration.
    command.check(_config())


def test_downgrade_and_upgrade_again():
    config = _config()
    command.downgrade(config, "base")
    engine = create_engine(TEST_URL)
    assert set(inspect(engine).get_table_names()) <= {"alembic_version"}
    command.upgrade(config, "head")
    assert {"users", "refresh_tokens", "devices", "feedback"} <= set(inspect(engine).get_table_names())
    engine.dispose()
