"""Retain attachment names and distinguish recoverable deletion from purging.

Revision ID: 0009_family_data_continuity
Revises: 0008_registration_activation_replay
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "0009_family_data_continuity"
down_revision = "0008_registration_activation_replay"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("media_assets", sa.Column("file_name", sa.String(255), nullable=True))
    for table in ("messages", "agendas", "memos", "notices"):
        op.add_column(table, sa.Column("purged_at", sa.DateTime(timezone=True), nullable=True))
        op.create_index(f"ix_{table}_recoverable", table, ["deleted_at"],
                        postgresql_where=sa.text("deleted_at IS NOT NULL AND purged_at IS NULL"))


def downgrade() -> None:
    # Development-only rollback. Production migrations are forward-only.
    for table in ("notices", "memos", "agendas", "messages"):
        op.drop_index(f"ix_{table}_recoverable", table_name=table)
        op.drop_column(table, "purged_at")
    op.drop_column("media_assets", "file_name")
