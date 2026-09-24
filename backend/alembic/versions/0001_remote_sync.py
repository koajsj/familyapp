"""Frozen initial PostgreSQL schema for the future remote-sync service.

This revision intentionally does not import the ORM. Its DDL is the
historical contract for an empty database; future model changes require new
revisions rather than altering this migration. Downgrade is for disposable
development databases only, never as a production rollback plan.
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "0001_remote_sync"
down_revision = None
branch_labels = None
depends_on = None

UUID = postgresql.UUID(as_uuid=True)
TIMESTAMPTZ = sa.DateTime(timezone=True)
JSON = sa.JSON()


def _sync_columns() -> list[sa.Column[object]]:
    return [
        sa.Column("version", sa.Integer(), nullable=False, server_default=sa.text("1")),
        sa.Column("created_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")),
        sa.Column("deleted_at", TIMESTAMPTZ, nullable=True),
    ]


def _uuid_id() -> sa.Column[object]:
    # Client-generated IDs preserve offline identity; the database must not
    # silently generate a different value.
    return sa.Column("id", UUID, primary_key=True, nullable=False)


def upgrade() -> None:
    op.create_table(
        "members", _uuid_id(),
        sa.Column("member_key", sa.String(32), nullable=False),
        sa.Column("display_name", sa.String(80), nullable=False),
        sa.Column("password_hash", sa.String(255), nullable=False),
        *_sync_columns(),
        sa.CheckConstraint("member_key IN ('Sendai', 'Osaka', 'Kyoto')", name="ck_member_fixed_key"),
        sa.UniqueConstraint("member_key"),
    )
    op.create_table(
        "devices", _uuid_id(),
        sa.Column("member_id", UUID, sa.ForeignKey("members.id", ondelete="CASCADE"), nullable=False),
        sa.Column("installation_id", sa.String(128), nullable=False),
        sa.Column("created_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")),
        sa.Column("last_seen_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")),
        sa.Column("last_acked_sync_seq", sa.BigInteger(), nullable=False, server_default=sa.text("0")),
        sa.Column("revoked_at", TIMESTAMPTZ),
        sa.UniqueConstraint("installation_id"),
    )
    op.create_index("ix_devices_member_id", "devices", ["member_id"])
    op.create_table(
        "refresh_sessions", _uuid_id(),
        sa.Column("member_id", UUID, sa.ForeignKey("members.id", ondelete="CASCADE"), nullable=False),
        sa.Column("device_id", UUID, sa.ForeignKey("devices.id", ondelete="CASCADE"), nullable=False),
        sa.Column("token_hash", sa.String(64), nullable=False),
        sa.Column("expires_at", TIMESTAMPTZ, nullable=False),
        sa.Column("created_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")),
        sa.Column("revoked_at", TIMESTAMPTZ),
        sa.Column("replaced_by_id", UUID, sa.ForeignKey("refresh_sessions.id", ondelete="SET NULL")),
        sa.UniqueConstraint("token_hash"),
    )
    op.create_index("ix_refresh_sessions_member_id", "refresh_sessions", ["member_id"])
    op.create_index("ix_refresh_sessions_device_id", "refresh_sessions", ["device_id"])
    op.create_table(
        "member_statuses", _uuid_id(),
        sa.Column("member_id", UUID, sa.ForeignKey("members.id", ondelete="CASCADE"), nullable=False),
        sa.Column("status_raw", sa.String(32), nullable=False, server_default=sa.text("'allGood'")),
        sa.Column("estimated_arrival", TIMESTAMPTZ), *_sync_columns(),
        sa.CheckConstraint("status_raw IN ('allGood', 'headingHome', 'atHome', 'atSchool')", name="ck_member_status_raw"),
        sa.CheckConstraint("(status_raw = 'headingHome') = (estimated_arrival IS NOT NULL)", name="ck_member_status_arrival"),
        sa.UniqueConstraint("member_id", name="uq_member_status_member"),
    )
    op.create_table("chats", _uuid_id(), *_sync_columns())
    op.create_table(
        "media_assets", _uuid_id(),
        sa.Column("owner_id", UUID, sa.ForeignKey("members.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("object_key", sa.String(512), nullable=False),
        sa.Column("mime_type", sa.String(128), nullable=False),
        sa.Column("size_bytes", sa.BigInteger(), nullable=False),
        sa.Column("checksum", sa.String(128), nullable=False),
        sa.Column("status", sa.String(32), nullable=False, server_default=sa.text("'pending'")),
        sa.Column("finalized_at", TIMESTAMPTZ), sa.Column("expires_at", TIMESTAMPTZ), *_sync_columns(),
        sa.CheckConstraint("size_bytes >= 0", name="ck_media_size"),
        sa.CheckConstraint("status IN ('pending', 'ready', 'missing')", name="ck_media_status"),
        sa.UniqueConstraint("object_key", name="uq_media_object_key"),
    )
    op.create_index("ix_media_assets_owner_id", "media_assets", ["owner_id"])
    op.create_table(
        "messages", _uuid_id(),
        sa.Column("chat_id", UUID, sa.ForeignKey("chats.id", ondelete="CASCADE"), nullable=False),
        sa.Column("sender_id", UUID, sa.ForeignKey("members.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("kind", sa.String(32), nullable=False), sa.Column("body", sa.Text()),
        sa.Column("media_id", UUID, sa.ForeignKey("media_assets.id", ondelete="SET NULL")),
        sa.Column("reply_to_id", UUID, sa.ForeignKey("messages.id", ondelete="SET NULL")),
        sa.Column("sent_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")),
        sa.Column("recalled_at", TIMESTAMPTZ), *_sync_columns(),
        sa.CheckConstraint("kind IN ('text', 'image', 'audio', 'recalled')", name="ck_message_kind"),
    )
    op.create_index("ix_messages_chat_id", "messages", ["chat_id"])
    op.create_index("ix_messages_sender_id", "messages", ["sender_id"])
    op.create_table(
        "message_receipts", _uuid_id(),
        sa.Column("message_id", UUID, sa.ForeignKey("messages.id", ondelete="CASCADE"), nullable=False),
        sa.Column("member_id", UUID, sa.ForeignKey("members.id", ondelete="CASCADE"), nullable=False),
        sa.Column("delivered_at", TIMESTAMPTZ), sa.Column("read_at", TIMESTAMPTZ), *_sync_columns(),
        sa.UniqueConstraint("message_id", "member_id", name="uq_message_receipt_member"),
    )
    op.create_index("ix_message_receipts_message_id", "message_receipts", ["message_id"])
    op.create_table(
        "semesters", _uuid_id(),
        sa.Column("name", sa.String(120), nullable=False), sa.Column("week1_start", sa.Date(), nullable=False),
        sa.Column("week1_end", sa.Date(), nullable=False), sa.Column("total_weeks", sa.Integer(), nullable=False),
        sa.Column("is_current", sa.Boolean(), nullable=False, server_default=sa.false()), *_sync_columns(),
        sa.CheckConstraint("total_weeks BETWEEN 1 AND 52", name="ck_semester_weeks"),
        sa.CheckConstraint("week1_end >= week1_start", name="ck_semester_first_week"),
    )
    op.create_table(
        "import_batches", _uuid_id(),
        sa.Column("semester_id", UUID, sa.ForeignKey("semesters.id", ondelete="CASCADE"), nullable=False),
        sa.Column("owner_id", UUID, sa.ForeignKey("members.id", ondelete="CASCADE"), nullable=False),
        sa.Column("source", sa.String(32), nullable=False), sa.Column("source_file_name", sa.String(255)),
        sa.Column("source_file_type", sa.String(64)), *_sync_columns(),
        sa.CheckConstraint("source IN ('photoLibrary', 'files', 'camera')", name="ck_import_source"),
    )
    op.create_index("ix_import_batches_semester_id", "import_batches", ["semester_id"])
    op.create_index("ix_import_batches_owner_id", "import_batches", ["owner_id"])
    op.create_table(
        "schedules", _uuid_id(),
        sa.Column("owner_id", UUID, sa.ForeignKey("members.id", ondelete="CASCADE"), nullable=False),
        sa.Column("semester_id", UUID, sa.ForeignKey("semesters.id", ondelete="CASCADE"), nullable=False),
        sa.Column("kind", sa.String(32), nullable=False), sa.Column("title", sa.String(200), nullable=False),
        sa.Column("weekday", sa.Integer(), nullable=False), sa.Column("start_minutes", sa.Integer(), nullable=False),
        sa.Column("end_minutes", sa.Integer(), nullable=False), sa.Column("start_week", sa.Integer(), nullable=False),
        sa.Column("end_week", sa.Integer(), nullable=False), sa.Column("week_type", sa.String(20), nullable=False),
        sa.Column("metadata_json", JSON, nullable=False, server_default=sa.text("'{}'::json")), *_sync_columns(),
        sa.CheckConstraint("weekday BETWEEN 1 AND 7", name="ck_schedule_weekday"),
        sa.CheckConstraint("start_minutes BETWEEN 0 AND 1439 AND end_minutes BETWEEN 1 AND 1440 AND start_minutes < end_minutes", name="ck_schedule_time"),
        sa.CheckConstraint("start_week >= 1 AND end_week >= start_week", name="ck_schedule_weeks"),
        sa.CheckConstraint("kind IN ('course', 'groupMeeting')", name="ck_schedule_kind"),
        sa.CheckConstraint("week_type IN ('everyWeek', 'oddWeek', 'evenWeek')", name="ck_schedule_week_type"),
    )
    op.create_index("ix_schedule_owner_semester", "schedules", ["owner_id", "semester_id"])
    op.create_table(
        "import_batch_items", _uuid_id(),
        sa.Column("batch_id", UUID, sa.ForeignKey("import_batches.id", ondelete="CASCADE"), nullable=False),
        sa.Column("schedule_id", UUID, sa.ForeignKey("schedules.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("operation", sa.String(16), nullable=False), sa.Column("before_snapshot", JSON),
        sa.Column("after_fingerprint", sa.String(512), nullable=False), *_sync_columns(),
        sa.CheckConstraint("operation IN ('created', 'updated')", name="ck_import_batch_item_operation"),
        sa.UniqueConstraint("batch_id", "schedule_id", name="uq_import_batch_item_schedule"),
    )
    op.create_index("ix_import_batch_items_batch_id", "import_batch_items", ["batch_id"])
    op.create_table(
        "schedule_exceptions", _uuid_id(),
        sa.Column("schedule_id", UUID, sa.ForeignKey("schedules.id", ondelete="CASCADE"), nullable=False),
        sa.Column("scope", sa.String(32), nullable=False), sa.Column("kind", sa.String(32), nullable=False),
        sa.Column("occurrence_date", sa.Date(), nullable=False), sa.Column("replacement_json", JSON), *_sync_columns(),
    )
    op.create_index("ix_schedule_exception_schedule", "schedule_exceptions", ["schedule_id", "occurrence_date"])
    op.create_table(
        "calendar_overrides", _uuid_id(),
        sa.Column("semester_id", UUID, sa.ForeignKey("semesters.id", ondelete="CASCADE"), nullable=False),
        sa.Column("date", sa.Date(), nullable=False), sa.Column("kind", sa.String(32), nullable=False),
        sa.Column("mapped_weekday", sa.Integer()), sa.Column("note", sa.Text()), *_sync_columns(),
        sa.CheckConstraint("kind IN ('holiday', 'normal', 'mappedWeekday')", name="ck_override_kind"),
        sa.CheckConstraint("mapped_weekday IS NULL OR mapped_weekday BETWEEN 1 AND 7", name="ck_override_weekday"),
        sa.UniqueConstraint("semester_id", "date", name="uq_calendar_override_day"),
    )
    op.create_table(
        "agendas", _uuid_id(),
        sa.Column("creator_id", UUID, sa.ForeignKey("members.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("kind", sa.String(32), nullable=False), sa.Column("title", sa.String(200), nullable=False),
        sa.Column("start_at", TIMESTAMPTZ), sa.Column("end_at", TIMESTAMPTZ), sa.Column("due_at", TIMESTAMPTZ),
        sa.Column("recurrence_rule", JSON), sa.Column("detail_json", JSON, nullable=False, server_default=sa.text("'{}'::json")),
        *_sync_columns(),
        sa.CheckConstraint("kind IN ('normal', 'exam', 'assignmentDeadline', 'orderFood')", name="ck_agenda_kind"),
        sa.CheckConstraint("end_at IS NULL OR start_at IS NULL OR start_at < end_at", name="ck_agenda_interval"),
    )
    op.create_index("ix_agendas_creator_id", "agendas", ["creator_id"])
    op.create_table(
        "agenda_participants", _uuid_id(),
        sa.Column("agenda_id", UUID, sa.ForeignKey("agendas.id", ondelete="CASCADE"), nullable=False),
        sa.Column("member_id", UUID, sa.ForeignKey("members.id", ondelete="RESTRICT"), nullable=False), *_sync_columns(),
        sa.UniqueConstraint("agenda_id", "member_id", name="uq_agenda_participant"),
    )
    op.create_index("ix_agenda_participants_agenda_id", "agenda_participants", ["agenda_id"])
    op.create_table(
        "agenda_exceptions", _uuid_id(),
        sa.Column("agenda_id", UUID, sa.ForeignKey("agendas.id", ondelete="CASCADE"), nullable=False),
        sa.Column("scope", sa.String(32), nullable=False), sa.Column("kind", sa.String(32), nullable=False),
        sa.Column("occurrence_date", sa.Date(), nullable=False), sa.Column("replacement_json", JSON), *_sync_columns(),
    )
    op.create_index("ix_agenda_exception_agenda", "agenda_exceptions", ["agenda_id", "occurrence_date"])
    op.create_table(
        "food_reads", _uuid_id(),
        sa.Column("agenda_id", UUID, sa.ForeignKey("agendas.id", ondelete="CASCADE"), nullable=False),
        sa.Column("member_id", UUID, sa.ForeignKey("members.id", ondelete="CASCADE"), nullable=False),
        sa.Column("read_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")), *_sync_columns(),
        sa.UniqueConstraint("agenda_id", "member_id", name="uq_food_read_member"),
    )
    op.create_index("ix_food_reads_agenda_id", "food_reads", ["agenda_id"])
    op.create_table(
        "memos", _uuid_id(),
        sa.Column("creator_id", UUID, sa.ForeignKey("members.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("title", sa.String(200)), sa.Column("content", sa.Text(), nullable=False),
        sa.Column("pinned", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("updated_by", UUID, sa.ForeignKey("members.id", ondelete="RESTRICT"), nullable=False), *_sync_columns(),
        sa.CheckConstraint("version > 0", name="ck_memo_version"),
    )
    op.create_table(
        "notices", _uuid_id(),
        sa.Column("publisher_id", UUID, sa.ForeignKey("members.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("title", sa.String(200), nullable=False), sa.Column("content", sa.Text(), nullable=False),
        sa.Column("pinned", sa.Boolean(), nullable=False, server_default=sa.false()), *_sync_columns(),
    )
    op.create_index("ix_notices_publisher_id", "notices", ["publisher_id"])
    op.create_table(
        "notice_reads", _uuid_id(),
        sa.Column("notice_id", UUID, sa.ForeignKey("notices.id", ondelete="CASCADE"), nullable=False),
        sa.Column("member_id", UUID, sa.ForeignKey("members.id", ondelete="CASCADE"), nullable=False),
        sa.Column("read_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")), *_sync_columns(),
        sa.UniqueConstraint("notice_id", "member_id", name="uq_notice_read_member"),
    )
    op.create_index("ix_notice_reads_notice_id", "notice_reads", ["notice_id"])
    op.create_table(
        "location_snapshots", _uuid_id(),
        sa.Column("member_id", UUID, sa.ForeignKey("members.id", ondelete="CASCADE"), nullable=False),
        sa.Column("latitude", sa.Float(), nullable=False), sa.Column("longitude", sa.Float(), nullable=False),
        sa.Column("captured_at", TIMESTAMPTZ, nullable=False), sa.Column("event_type", sa.String(32)),
        sa.CheckConstraint("latitude BETWEEN -90 AND 90", name="ck_location_latitude"),
        sa.CheckConstraint("longitude BETWEEN -180 AND 180", name="ck_location_longitude"),
    )
    op.create_index("ix_location_member_captured", "location_snapshots", ["member_id", "captured_at"])
    op.create_table(
        "member_places", _uuid_id(),
        sa.Column("member_id", UUID, sa.ForeignKey("members.id", ondelete="CASCADE"), nullable=False),
        sa.Column("type", sa.String(32), nullable=False), sa.Column("name", sa.String(120), nullable=False),
        sa.Column("latitude", sa.Float(), nullable=False), sa.Column("longitude", sa.Float(), nullable=False),
        sa.Column("radius_m", sa.Integer(), nullable=False), sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
        *_sync_columns(),
        sa.CheckConstraint("type IN ('home', 'school', 'company', 'custom')", name="ck_place_type"),
        sa.CheckConstraint("latitude BETWEEN -90 AND 90", name="ck_place_latitude"),
        sa.CheckConstraint("longitude BETWEEN -180 AND 180", name="ck_place_longitude"),
        sa.CheckConstraint("radius_m IN (100, 200, 500, 1000)", name="ck_place_radius"),
    )
    op.create_index("ix_member_places_member_id", "member_places", ["member_id"])
    op.create_index("uq_enabled_home_per_member", "member_places", ["member_id"], unique=True, postgresql_where=sa.text("type = 'home' AND enabled AND deleted_at IS NULL"))
    op.create_index("uq_enabled_school_per_member", "member_places", ["member_id"], unique=True, postgresql_where=sa.text("type = 'school' AND enabled AND deleted_at IS NULL"))
    op.create_table(
        "geofence_events", _uuid_id(),
        sa.Column("place_id", UUID, sa.ForeignKey("member_places.id", ondelete="CASCADE"), nullable=False),
        sa.Column("member_id", UUID, sa.ForeignKey("members.id", ondelete="CASCADE"), nullable=False),
        sa.Column("event_type", sa.String(16), nullable=False), sa.Column("occurred_at", TIMESTAMPTZ, nullable=False), *_sync_columns(),
        sa.CheckConstraint("event_type IN ('arrive', 'leave')", name="ck_geofence_event_type"),
    )
    op.create_index("ix_geofence_events_place_id", "geofence_events", ["place_id"])
    op.create_table(
        "processed_mutations", _uuid_id(),
        sa.Column("mutation_id", UUID, nullable=False),
        sa.Column("device_id", UUID, sa.ForeignKey("devices.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("result_json", JSON, nullable=False),
        sa.Column("processed_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")),
        sa.UniqueConstraint("mutation_id"),
    )
    op.create_index("ix_processed_mutations_device_id", "processed_mutations", ["device_id"])
    op.create_table(
        "sync_changes",
        sa.Column("seq", sa.BigInteger(), primary_key=True, nullable=False, autoincrement=False),
        sa.Column("entity_type", sa.String(64), nullable=False), sa.Column("entity_id", UUID, nullable=False),
        sa.Column("operation", sa.String(16), nullable=False), sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("payload", JSON), sa.Column("source_mutation_id", UUID),
        sa.Column("source_device_id", UUID, sa.ForeignKey("devices.id", ondelete="SET NULL")),
        sa.Column("updated_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")),
        sa.UniqueConstraint("source_mutation_id"),
    )
    op.create_index("ix_sync_change_entity", "sync_changes", ["entity_type", "entity_id"])
    op.create_index("ix_sync_changes_source_device_id", "sync_changes", ["source_device_id"])
    op.create_table(
        "sync_heads",
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("committed_seq", sa.BigInteger(), nullable=False, server_default=sa.text("0")),
        sa.Column("updated_at", TIMESTAMPTZ, nullable=False, server_default=sa.text("now()")),
    )


def downgrade() -> None:
    # Reverse order only for disposable development databases.
    for table_name in (
        "sync_heads", "sync_changes", "processed_mutations", "geofence_events",
        "member_places", "location_snapshots", "notice_reads", "notices", "memos",
        "food_reads", "agenda_exceptions", "agenda_participants", "agendas",
        "calendar_overrides", "schedule_exceptions", "import_batch_items", "schedules",
        "import_batches", "semesters", "message_receipts", "messages", "media_assets",
        "chats", "member_statuses", "refresh_sessions", "devices", "members",
    ):
        op.drop_table(table_name)
