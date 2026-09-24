"""Add non-replicated recovery credentials and one-use recovery sessions.

Recovery records are an authentication control-plane concern. They are not
sync entities and must never appear in a SyncChange or a client backup.
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "0002_recovery_control_plane"
down_revision = "0001_remote_sync"
branch_labels = None
depends_on = None

UUID = postgresql.UUID(as_uuid=True)
TIMESTAMPTZ = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "recovery_credentials",
        sa.Column("id", UUID, primary_key=True, nullable=False),
        sa.Column("member_id", UUID, sa.ForeignKey("members.id", ondelete="CASCADE"), nullable=False),
        sa.Column("verifier", sa.String(512), nullable=False),
        sa.Column("generation", sa.Integer(), nullable=False, server_default=sa.text("1")),
        sa.Column("created_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")),
        sa.Column("rotated_at", TIMESTAMPTZ),
        sa.Column("failed_attempts", sa.Integer(), nullable=False, server_default=sa.text("0")),
        sa.Column("next_allowed_at", TIMESTAMPTZ),
        sa.CheckConstraint("generation >= 1", name="ck_recovery_credential_generation"),
        sa.CheckConstraint("failed_attempts >= 0", name="ck_recovery_credential_attempts"),
        sa.UniqueConstraint("member_id", name="uq_recovery_credential_member"),
    )
    op.create_index("ix_recovery_credentials_member_id", "recovery_credentials", ["member_id"])
    op.create_table(
        "recovery_sessions",
        sa.Column("id", UUID, primary_key=True, nullable=False),
        sa.Column("member_id", UUID, sa.ForeignKey("members.id", ondelete="CASCADE"), nullable=False),
        sa.Column("token_hash", sa.String(64), nullable=False),
        sa.Column("purpose", sa.String(32), nullable=False),
        sa.Column("recovery_generation", sa.Integer(), nullable=False),
        sa.Column("expires_at", TIMESTAMPTZ, nullable=False),
        sa.Column("used_at", TIMESTAMPTZ),
        sa.Column("created_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")),
        sa.CheckConstraint(
            "purpose IN ('forgot_password', 'new_device', 'account_takeover')",
            name="ck_recovery_session_purpose",
        ),
        sa.CheckConstraint("recovery_generation >= 1", name="ck_recovery_session_generation"),
        sa.UniqueConstraint("token_hash", name="uq_recovery_session_token_hash"),
    )
    op.create_index("ix_recovery_sessions_member_id", "recovery_sessions", ["member_id"])
    op.create_index("ix_recovery_sessions_expires_at", "recovery_sessions", ["expires_at"])


def downgrade() -> None:
    # Only for disposable development databases; production rollback requires
    # a forward recovery plan because it would discard authentication records.
    op.drop_index("ix_recovery_sessions_expires_at", table_name="recovery_sessions")
    op.drop_index("ix_recovery_sessions_member_id", table_name="recovery_sessions")
    op.drop_table("recovery_sessions")
    op.drop_index("ix_recovery_credentials_member_id", table_name="recovery_credentials")
    op.drop_table("recovery_credentials")
