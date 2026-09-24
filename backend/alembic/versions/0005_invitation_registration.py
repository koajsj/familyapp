"""Add invitation-gated pending registrations and active nickname uniqueness.

This is a control-plane-only schema. Pending applications are intentionally not
sync records and cannot become normal Members before an authenticated member
approves them.
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "0005_invitation_registration"
down_revision = "0004_dynamic_member_compatibility"
branch_labels = None
depends_on = None

UUID = postgresql.UUID(as_uuid=True)
TIMESTAMPTZ = sa.DateTime(timezone=True)


def upgrade() -> None:
    # Keep current provisioned identities intact while giving every existing
    # row an explicit normalized display-name key before adding the constraint.
    op.add_column("members", sa.Column("normalized_display_name", sa.String(length=160), nullable=True))
    op.execute("UPDATE members SET normalized_display_name = lower(btrim(display_name)) WHERE normalized_display_name IS NULL")
    op.alter_column("members", "normalized_display_name", nullable=False)
    op.create_index(
        "uq_members_normalized_display_name_active", "members", ["normalized_display_name"], unique=True,
        postgresql_where=sa.text("deleted_at IS NULL"),
    )

    op.create_table(
        "pending_registrations",
        sa.Column("id", UUID, primary_key=True, nullable=False),
        sa.Column("display_name", sa.String(length=80), nullable=False),
        sa.Column("normalized_display_name", sa.String(length=160), nullable=False),
        sa.Column("password_hash", sa.String(length=255), nullable=False),
        sa.Column("installation_id", sa.String(length=128), nullable=False),
        sa.Column("activation_token_hash", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False, server_default=sa.text("'pending'")),
        sa.Column("member_id", UUID, sa.ForeignKey("members.id", ondelete="SET NULL")),
        sa.Column("approved_by", UUID, sa.ForeignKey("members.id", ondelete="SET NULL")),
        sa.Column("rejected_by", UUID, sa.ForeignKey("members.id", ondelete="SET NULL")),
        sa.Column("created_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")),
        sa.Column("expires_at", TIMESTAMPTZ, nullable=False),
        sa.Column("decided_at", TIMESTAMPTZ),
        sa.Column("activated_at", TIMESTAMPTZ),
        sa.CheckConstraint("status IN ('pending', 'approved', 'rejected')", name="ck_pending_registration_status"),
        sa.CheckConstraint("expires_at > created_at", name="ck_pending_registration_expiry"),
        sa.UniqueConstraint("activation_token_hash", name="uq_pending_registration_activation_token"),
    )
    op.create_index("ix_pending_registrations_member_id", "pending_registrations", ["member_id"])
    op.create_index("ix_pending_registrations_approved_by", "pending_registrations", ["approved_by"])
    op.create_index("ix_pending_registrations_rejected_by", "pending_registrations", ["rejected_by"])
    op.create_index(
        "uq_pending_registration_normalized_name_pending", "pending_registrations", ["normalized_display_name"], unique=True,
        postgresql_where=sa.text("status = 'pending'"),
    )
    op.create_index(
        "uq_pending_registration_installation_pending", "pending_registrations", ["installation_id"], unique=True,
        postgresql_where=sa.text("status = 'pending'"),
    )


def downgrade() -> None:
    # For disposable development databases only. Production rollback should be
    # a forward migration because it would discard application audit records.
    op.drop_index("uq_pending_registration_installation_pending", table_name="pending_registrations")
    op.drop_index("uq_pending_registration_normalized_name_pending", table_name="pending_registrations")
    op.drop_index("ix_pending_registrations_rejected_by", table_name="pending_registrations")
    op.drop_index("ix_pending_registrations_approved_by", table_name="pending_registrations")
    op.drop_index("ix_pending_registrations_member_id", table_name="pending_registrations")
    op.drop_table("pending_registrations")
    op.drop_index("uq_members_normalized_display_name_active", table_name="members")
    op.drop_column("members", "normalized_display_name")
