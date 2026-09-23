"""Bounded replay for a lost registration activation response.

Revision ID: 0008_registration_activation_replay
Revises: 0007_multi_device_location_source
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "0008_registration_activation_replay"
down_revision = "0007_multi_device_location_source"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "pending_registrations",
        sa.Column("activation_replay_until", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    # Retained only for disposable development databases; production changes
    # must continue forward with a new migration.
    op.drop_column("pending_registrations", "activation_replay_until")
