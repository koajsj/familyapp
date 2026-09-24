"""Permit the existing Message/MediaAsset association for chat documents.

Revision ID: 0010_chat_file_attachments
Revises: 0009_family_data_continuity
"""
from __future__ import annotations

from alembic import op


revision = "0010_chat_file_attachments"
down_revision = "0009_family_data_continuity"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_constraint("ck_message_kind", "messages", type_="check")
    op.create_check_constraint(
        "ck_message_kind", "messages",
        "kind IN ('text', 'image', 'audio', 'file', 'recalled')",
    )


def downgrade() -> None:
    # Downgrading after file messages exist would destroy their message kind.
    raise RuntimeError("chat file attachments cannot be safely downgraded")
