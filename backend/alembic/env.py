"""Alembic environment for the async PostgreSQL remote-service schema.

Revisions are explicit DDL, so this module deliberately does not import ORM
metadata. That prevents a future model change from mutating migration history.
"""
from __future__ import annotations

import asyncio

from alembic import context
from sqlalchemy import pool
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import async_engine_from_config

from app.config import Settings


config = context.config
target_metadata = None


def _async_database_url(raw_url: str) -> str:
    """Normalize the configured PostgreSQL URL for SQLAlchemy async engines."""
    url = make_url(raw_url)
    if url.drivername == "postgresql":
        url = url.set(drivername="postgresql+asyncpg")
    if url.drivername != "postgresql+asyncpg":
        raise ValueError("DATABASE_URL must use PostgreSQL with asyncpg")
    return url.render_as_string(hide_password=False)


def _offline_database_url(async_url: str) -> str:
    """Alembic SQL rendering needs the PostgreSQL dialect, not asyncpg."""
    return make_url(async_url).set(drivername="postgresql").render_as_string(hide_password=False)


database_url = _async_database_url(Settings.from_environment().database_url)
config.set_main_option("sqlalchemy.url", database_url)


def run_migrations_offline() -> None:
    context.configure(
        url=_offline_database_url(database_url),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection) -> None:
    context.configure(connection=connection, target_metadata=target_metadata)
    with context.begin_transaction():
        context.run_migrations()


async def run_async_migrations() -> None:
    connectable = async_engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await connectable.dispose()


def run_migrations_online() -> None:
    asyncio.run(run_async_migrations())


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
