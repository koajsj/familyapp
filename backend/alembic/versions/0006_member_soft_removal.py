"""Add auditable dynamic-member departure and removal approval support.

Member rows remain soft-deleted through their existing ``deleted_at`` field;
no historical business foreign key is cascaded or physically removed.
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "0006_member_soft_removal"
down_revision = "0005_invitation_registration"
branch_labels = None
depends_on = None

UUID = postgresql.UUID(as_uuid=True)
TIMESTAMPTZ = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.add_column("recovery_credentials", sa.Column("invalidated_at", TIMESTAMPTZ, nullable=True))
    op.create_table(
        "member_removal_requests",
        sa.Column("id", UUID, primary_key=True, nullable=False),
        sa.Column("target_member_id", UUID, sa.ForeignKey("members.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("requester_id", UUID, sa.ForeignKey("members.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("approver_id", UUID, sa.ForeignKey("members.id", ondelete="RESTRICT"), nullable=True),
        sa.Column("status", sa.String(length=16), nullable=False, server_default=sa.text("'pending'")),
        sa.Column("created_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")),
        sa.Column("decided_at", TIMESTAMPTZ, nullable=True),
        sa.CheckConstraint("status IN ('pending', 'approved', 'rejected', 'cancelled')", name="ck_member_removal_request_status"),
        sa.CheckConstraint("requester_id <> target_member_id", name="ck_member_removal_request_distinct_requester"),
    )
    op.create_index("ix_member_removal_requests_target_member_id", "member_removal_requests", ["target_member_id"])
    op.create_index("ix_member_removal_requests_requester_id", "member_removal_requests", ["requester_id"])
    op.create_index("ix_member_removal_requests_approver_id", "member_removal_requests", ["approver_id"])
    op.create_index(
        "uq_member_removal_request_target_pending", "member_removal_requests", ["target_member_id"], unique=True,
        postgresql_where=sa.text("status = 'pending'"),
    )


def downgrade() -> None:
    # Only for disposable environments. Production rollback should be a
    # forward migration so removal audit records are never discarded.
    op.drop_index("uq_member_removal_request_target_pending", table_name="member_removal_requests")
    op.drop_index("ix_member_removal_requests_approver_id", table_name="member_removal_requests")
    op.drop_index("ix_member_removal_requests_requester_id", table_name="member_removal_requests")
    op.drop_index("ix_member_removal_requests_target_member_id", table_name="member_removal_requests")
    op.drop_table("member_removal_requests")
    op.drop_column("recovery_credentials", "invalidated_at")
