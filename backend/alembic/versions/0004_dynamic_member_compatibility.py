"""Permit provisioned UUID-backed members without changing initial identities.

The original Sendai/Osaka/Kyoto rows retain their primary keys and member keys.
This revision only removes the three-key check, expands the opaque login key,
and records presentation/protection metadata for future control-plane member
provisioning. It does not add registration or member-deletion endpoints.
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "0004_dynamic_member_compatibility"
down_revision = "0003_location_snapshot_metadata"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_constraint("ck_member_fixed_key", "members", type_="check")
    op.alter_column("members", "member_key", existing_type=sa.String(length=32), type_=sa.String(length=80))
    op.add_column("members", sa.Column("avatar_symbol", sa.String(length=128), nullable=True))
    op.add_column("members", sa.Column("is_initial_member", sa.Boolean(), nullable=False, server_default=sa.false()))
    op.execute("UPDATE members SET is_initial_member = TRUE WHERE member_key IN ('Sendai', 'Osaka', 'Kyoto')")


def downgrade() -> None:
    # Only safe for a disposable database with no later provisioned members.
    op.drop_column("members", "is_initial_member")
    op.drop_column("members", "avatar_symbol")
    op.alter_column("members", "member_key", existing_type=sa.String(length=80), type_=sa.String(length=32))
    op.create_check_constraint("ck_member_fixed_key", "members", "member_key IN ('Sendai', 'Osaka', 'Kyoto')")
