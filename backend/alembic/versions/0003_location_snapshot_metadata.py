"""Add optional accuracy and source metadata to immutable location snapshots.

Existing snapshots remain valid: their missing values are intentionally read by
iOS as legacy manual records rather than guessed as automatic tracking.
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "0003_location_snapshot_metadata"
down_revision = "0002_recovery_control_plane"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("location_snapshots", sa.Column("horizontal_accuracy", sa.Float(), nullable=True))
    op.add_column("location_snapshots", sa.Column("source", sa.String(length=16), nullable=True))
    op.create_check_constraint(
        "ck_location_horizontal_accuracy",
        "location_snapshots",
        "horizontal_accuracy IS NULL OR horizontal_accuracy >= 0",
    )
    op.create_check_constraint(
        "ck_location_source",
        "location_snapshots",
        "source IS NULL OR source IN ('automatic', 'manual')",
    )


def downgrade() -> None:
    op.drop_constraint("ck_location_source", "location_snapshots", type_="check")
    op.drop_constraint("ck_location_horizontal_accuracy", "location_snapshots", type_="check")
    op.drop_column("location_snapshots", "source")
    op.drop_column("location_snapshots", "horizontal_accuracy")
