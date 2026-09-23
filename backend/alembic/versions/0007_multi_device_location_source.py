"""Track device presentation metadata and one automatic location source.

The partial index is intentionally scoped to non-revoked devices: historical
device records remain auditable after a sign-out or account takeover, without
blocking a later device from being selected as the member's source.
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "0007_multi_device_location_source"
down_revision = "0006_member_soft_removal"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("devices", sa.Column("display_name", sa.String(length=128), nullable=True))
    op.execute("UPDATE devices SET display_name = '此设备' WHERE display_name IS NULL")
    op.alter_column("devices", "display_name", nullable=False)
    op.add_column(
        "devices",
        sa.Column("is_location_source", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.create_index(
        "uq_device_active_location_source",
        "devices",
        ["member_id"],
        unique=True,
        postgresql_where=sa.text("is_location_source AND revoked_at IS NULL"),
    )


def downgrade() -> None:
    # Production changes should use a forward migration. This downgrade is
    # retained only for disposable development databases.
    op.drop_index("uq_device_active_location_source", table_name="devices")
    op.drop_column("devices", "is_location_source")
    op.drop_column("devices", "display_name")
