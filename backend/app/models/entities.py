"""PostgreSQL entities for the future FamilyApp remote-sync service.

Importing these models is side-effect free. The current iOS app remains localOnly.
"""
from __future__ import annotations

from datetime import date, datetime
from uuid import UUID, uuid4

from sqlalchemy import (
    BigInteger, Boolean, CheckConstraint, Date, DateTime, Float, ForeignKey,
    Index, Integer, JSON, String, Text, UniqueConstraint, func, text,
)
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


def uuid_pk() -> Mapped[UUID]:
    return mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid4)


class SyncRecord:
    """Fields shared by mutable records replicated across devices."""
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now(), onupdate=func.now())
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Member(Base, SyncRecord):
    __tablename__ = "members"
    id: Mapped[UUID] = uuid_pk()
    member_key: Mapped[str] = mapped_column(String(80), unique=True, nullable=False)
    display_name: Mapped[str] = mapped_column(String(80), nullable=False)
    # Never use presentation text as a foreign key. This value is only the
    # normalized uniqueness key for active family members.
    normalized_display_name: Mapped[str] = mapped_column(String(160), nullable=False)
    avatar_symbol: Mapped[str | None] = mapped_column(String(128))
    is_initial_member: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)


class MemberRemovalRequest(Base):
    """Two-person approval record for removing a non-initial member.

    This control-plane audit row is intentionally outside SyncChange.  The
    resulting Member tombstone is the only replicated identity change.
    """
    __tablename__ = "member_removal_requests"
    __table_args__ = (
        CheckConstraint("status IN ('pending', 'approved', 'rejected', 'cancelled')", name="ck_member_removal_request_status"),
        CheckConstraint("requester_id <> target_member_id", name="ck_member_removal_request_distinct_requester"),
        Index(
            "uq_member_removal_request_target_pending", "target_member_id", unique=True,
            postgresql_where=text("status = 'pending'"),
        ),
    )
    id: Mapped[UUID] = uuid_pk()
    target_member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), index=True, nullable=False)
    requester_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), index=True, nullable=False)
    approver_id: Mapped[UUID | None] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), index=True)
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="pending")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class PendingRegistration(Base):
    """Pre-membership request bound to one installation, never a sync record.

    The applicant holds the opaque activation token; PostgreSQL retains only
    its hash. A pending row cannot be used by normal auth or business routes.
    """
    __tablename__ = "pending_registrations"
    __table_args__ = (
        CheckConstraint("status IN ('pending', 'approved', 'rejected')", name="ck_pending_registration_status"),
        CheckConstraint("expires_at > created_at", name="ck_pending_registration_expiry"),
        Index(
            "uq_pending_registration_normalized_name_pending", "normalized_display_name", unique=True,
            postgresql_where=text("status = 'pending'"),
        ),
        Index(
            "uq_pending_registration_installation_pending", "installation_id", unique=True,
            postgresql_where=text("status = 'pending'"),
        ),
    )
    id: Mapped[UUID] = uuid_pk()
    display_name: Mapped[str] = mapped_column(String(80), nullable=False)
    normalized_display_name: Mapped[str] = mapped_column(String(160), nullable=False)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    installation_id: Mapped[str] = mapped_column(String(128), nullable=False)
    # This is an opaque applicant capability, not an access/refresh token.
    activation_token_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="pending")
    member_id: Mapped[UUID | None] = mapped_column(ForeignKey("members.id", ondelete="SET NULL"), index=True)
    approved_by: Mapped[UUID | None] = mapped_column(ForeignKey("members.id", ondelete="SET NULL"), index=True)
    rejected_by: Mapped[UUID | None] = mapped_column(ForeignKey("members.id", ondelete="SET NULL"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    activated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # A short post-commit replay window permits the same installation to
    # recover one lost activation response without keeping the capability
    # usable for the whole pending-registration lifetime.
    activation_replay_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Device(Base):
    __tablename__ = "devices"
    __table_args__ = (
        # A revoked device may retain its historical flag, but no active
        # member can have two automatic location-source devices.
        Index(
            "uq_device_active_location_source", "member_id", unique=True,
            postgresql_where=text("is_location_source AND revoked_at IS NULL"),
        ),
    )
    id: Mapped[UUID] = uuid_pk()
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), index=True, nullable=False)
    installation_id: Mapped[str] = mapped_column(String(128), unique=True, nullable=False)
    display_name: Mapped[str] = mapped_column(String(128), nullable=False, default="此设备")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    last_acked_sync_seq: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    is_location_source: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)


class RefreshSession(Base):
    __tablename__ = "refresh_sessions"
    id: Mapped[UUID] = uuid_pk()
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), index=True, nullable=False)
    device_id: Mapped[UUID] = mapped_column(ForeignKey("devices.id", ondelete="CASCADE"), index=True, nullable=False)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    replaced_by_id: Mapped[UUID | None] = mapped_column(ForeignKey("refresh_sessions.id", ondelete="SET NULL"))


class RecoveryCredential(Base):
    """Non-replicated verifier for a member's client-generated recovery secret."""
    __tablename__ = "recovery_credentials"
    __table_args__ = (
        UniqueConstraint("member_id", name="uq_recovery_credential_member"),
        CheckConstraint("generation >= 1", name="ck_recovery_credential_generation"),
        CheckConstraint("failed_attempts >= 0", name="ck_recovery_credential_attempts"),
    )
    id: Mapped[UUID] = uuid_pk()
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), nullable=False)
    verifier: Mapped[str] = mapped_column(String(512), nullable=False)
    generation: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    rotated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    failed_attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    next_allowed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # Retained for audit without permitting a removed member to reuse the
    # credential if its Member row is ever inspected by a control-plane path.
    invalidated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class RecoverySession(Base):
    """Short-lived, single-purpose recovery authorization; not an auth session."""
    __tablename__ = "recovery_sessions"
    __table_args__ = (
        CheckConstraint("purpose IN ('forgot_password', 'new_device', 'account_takeover')", name="ck_recovery_session_purpose"),
        CheckConstraint("recovery_generation >= 1", name="ck_recovery_session_generation"),
        UniqueConstraint("token_hash", name="uq_recovery_session_token_hash"),
    )
    id: Mapped[UUID] = uuid_pk()
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), index=True, nullable=False)
    token_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    purpose: Mapped[str] = mapped_column(String(32), nullable=False)
    recovery_generation: Mapped[int] = mapped_column(Integer, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class MemberStatus(Base, SyncRecord):
    __tablename__ = "member_statuses"
    __table_args__ = (
        UniqueConstraint("member_id", name="uq_member_status_member"),
        CheckConstraint("status_raw IN ('allGood', 'headingHome', 'atHome', 'atSchool')", name="ck_member_status_raw"),
        CheckConstraint("(status_raw = 'headingHome') = (estimated_arrival IS NOT NULL)", name="ck_member_status_arrival"),
    )
    id: Mapped[UUID] = uuid_pk()
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), nullable=False)
    status_raw: Mapped[str] = mapped_column(String(32), nullable=False, default="allGood")
    estimated_arrival: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Chat(Base, SyncRecord):
    __tablename__ = "chats"
    id: Mapped[UUID] = uuid_pk()


class MediaAsset(Base, SyncRecord):
    __tablename__ = "media_assets"
    __table_args__ = (
        UniqueConstraint("object_key", name="uq_media_object_key"),
        CheckConstraint("size_bytes >= 0", name="ck_media_size"),
        CheckConstraint("status IN ('pending', 'ready', 'missing')", name="ck_media_status"),
    )
    id: Mapped[UUID] = uuid_pk()
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), index=True, nullable=False)
    object_key: Mapped[str] = mapped_column(String(512), nullable=False)
    mime_type: Mapped[str] = mapped_column(String(128), nullable=False)
    size_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False)
    checksum: Mapped[str] = mapped_column(String(128), nullable=False)
    status: Mapped[str] = mapped_column(String(32), nullable=False, default="pending")
    finalized_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Message(Base, SyncRecord):
    __tablename__ = "messages"
    __table_args__ = (CheckConstraint("kind IN ('text', 'image', 'audio', 'recalled')", name="ck_message_kind"),)
    id: Mapped[UUID] = uuid_pk()
    chat_id: Mapped[UUID] = mapped_column(ForeignKey("chats.id", ondelete="CASCADE"), index=True, nullable=False)
    sender_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), index=True, nullable=False)
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    body: Mapped[str | None] = mapped_column(Text)
    media_id: Mapped[UUID | None] = mapped_column(ForeignKey("media_assets.id", ondelete="SET NULL"))
    reply_to_id: Mapped[UUID | None] = mapped_column(ForeignKey("messages.id", ondelete="SET NULL"))
    sent_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    recalled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class MessageReceipt(Base, SyncRecord):
    __tablename__ = "message_receipts"
    __table_args__ = (UniqueConstraint("message_id", "member_id", name="uq_message_receipt_member"),)
    id: Mapped[UUID] = uuid_pk()
    message_id: Mapped[UUID] = mapped_column(ForeignKey("messages.id", ondelete="CASCADE"), index=True, nullable=False)
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), nullable=False)
    delivered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Semester(Base, SyncRecord):
    __tablename__ = "semesters"
    __table_args__ = (CheckConstraint("total_weeks BETWEEN 1 AND 52", name="ck_semester_weeks"), CheckConstraint("week1_end >= week1_start", name="ck_semester_first_week"))
    id: Mapped[UUID] = uuid_pk()
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    week1_start: Mapped[date] = mapped_column(Date, nullable=False)
    week1_end: Mapped[date] = mapped_column(Date, nullable=False)
    total_weeks: Mapped[int] = mapped_column(Integer, nullable=False)
    is_current: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)


class ImportBatch(Base, SyncRecord):
    __tablename__ = "import_batches"
    __table_args__ = (CheckConstraint("source IN ('photoLibrary', 'files', 'camera')", name="ck_import_source"),)
    id: Mapped[UUID] = uuid_pk()
    semester_id: Mapped[UUID] = mapped_column(ForeignKey("semesters.id", ondelete="CASCADE"), index=True, nullable=False)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), index=True, nullable=False)
    source: Mapped[str] = mapped_column(String(32), nullable=False)
    source_file_name: Mapped[str | None] = mapped_column(String(255))
    source_file_type: Mapped[str | None] = mapped_column(String(64))


class Schedule(Base, SyncRecord):
    __tablename__ = "schedules"
    __table_args__ = (Index("ix_schedule_owner_semester", "owner_id", "semester_id"), CheckConstraint("weekday BETWEEN 1 AND 7", name="ck_schedule_weekday"), CheckConstraint("start_minutes BETWEEN 0 AND 1439 AND end_minutes BETWEEN 1 AND 1440 AND start_minutes < end_minutes", name="ck_schedule_time"), CheckConstraint("start_week >= 1 AND end_week >= start_week", name="ck_schedule_weeks"), CheckConstraint("kind IN ('course', 'groupMeeting')", name="ck_schedule_kind"), CheckConstraint("week_type IN ('everyWeek', 'oddWeek', 'evenWeek')", name="ck_schedule_week_type"))
    id: Mapped[UUID] = uuid_pk()
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), nullable=False)
    semester_id: Mapped[UUID] = mapped_column(ForeignKey("semesters.id", ondelete="CASCADE"), nullable=False)
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    weekday: Mapped[int] = mapped_column(Integer, nullable=False)
    start_minutes: Mapped[int] = mapped_column(Integer, nullable=False)
    end_minutes: Mapped[int] = mapped_column(Integer, nullable=False)
    start_week: Mapped[int] = mapped_column(Integer, nullable=False)
    end_week: Mapped[int] = mapped_column(Integer, nullable=False)
    week_type: Mapped[str] = mapped_column(String(20), nullable=False)
    metadata_json: Mapped[dict] = mapped_column(JSON, nullable=False, default=dict)


class ImportBatchItem(Base, SyncRecord):
    __tablename__ = "import_batch_items"
    __table_args__ = (UniqueConstraint("batch_id", "schedule_id", name="uq_import_batch_item_schedule"), CheckConstraint("operation IN ('created', 'updated')", name="ck_import_batch_item_operation"))
    id: Mapped[UUID] = uuid_pk()
    batch_id: Mapped[UUID] = mapped_column(ForeignKey("import_batches.id", ondelete="CASCADE"), index=True, nullable=False)
    schedule_id: Mapped[UUID] = mapped_column(ForeignKey("schedules.id", ondelete="RESTRICT"), nullable=False)
    operation: Mapped[str] = mapped_column(String(16), nullable=False)
    before_snapshot: Mapped[dict | None] = mapped_column(JSON)
    after_fingerprint: Mapped[str] = mapped_column(String(512), nullable=False)


class ScheduleException(Base, SyncRecord):
    __tablename__ = "schedule_exceptions"
    __table_args__ = (Index("ix_schedule_exception_schedule", "schedule_id", "occurrence_date"),)
    id: Mapped[UUID] = uuid_pk()
    schedule_id: Mapped[UUID] = mapped_column(ForeignKey("schedules.id", ondelete="CASCADE"), nullable=False)
    scope: Mapped[str] = mapped_column(String(32), nullable=False)
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    occurrence_date: Mapped[date] = mapped_column(Date, nullable=False)
    replacement_json: Mapped[dict | None] = mapped_column(JSON)


class CalendarOverride(Base, SyncRecord):
    __tablename__ = "calendar_overrides"
    __table_args__ = (UniqueConstraint("semester_id", "date", name="uq_calendar_override_day"), CheckConstraint("kind IN ('holiday', 'normal', 'mappedWeekday')", name="ck_override_kind"), CheckConstraint("mapped_weekday IS NULL OR mapped_weekday BETWEEN 1 AND 7", name="ck_override_weekday"))
    id: Mapped[UUID] = uuid_pk()
    semester_id: Mapped[UUID] = mapped_column(ForeignKey("semesters.id", ondelete="CASCADE"), nullable=False)
    date: Mapped[date] = mapped_column(Date, nullable=False)
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    mapped_weekday: Mapped[int | None] = mapped_column(Integer)
    note: Mapped[str | None] = mapped_column(Text)


class Agenda(Base, SyncRecord):
    __tablename__ = "agendas"
    __table_args__ = (CheckConstraint("kind IN ('normal', 'exam', 'assignmentDeadline', 'orderFood')", name="ck_agenda_kind"), CheckConstraint("end_at IS NULL OR start_at IS NULL OR start_at < end_at", name="ck_agenda_interval"))
    id: Mapped[UUID] = uuid_pk()
    creator_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), index=True, nullable=False)
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    start_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    end_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    recurrence_rule: Mapped[dict | None] = mapped_column(JSON)
    detail_json: Mapped[dict] = mapped_column(JSON, nullable=False, default=dict)


class AgendaParticipant(Base, SyncRecord):
    __tablename__ = "agenda_participants"
    __table_args__ = (UniqueConstraint("agenda_id", "member_id", name="uq_agenda_participant"),)
    id: Mapped[UUID] = uuid_pk()
    agenda_id: Mapped[UUID] = mapped_column(ForeignKey("agendas.id", ondelete="CASCADE"), index=True, nullable=False)
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), nullable=False)


class AgendaException(Base, SyncRecord):
    __tablename__ = "agenda_exceptions"
    __table_args__ = (Index("ix_agenda_exception_agenda", "agenda_id", "occurrence_date"),)
    id: Mapped[UUID] = uuid_pk()
    agenda_id: Mapped[UUID] = mapped_column(ForeignKey("agendas.id", ondelete="CASCADE"), nullable=False)
    scope: Mapped[str] = mapped_column(String(32), nullable=False)
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    occurrence_date: Mapped[date] = mapped_column(Date, nullable=False)
    replacement_json: Mapped[dict | None] = mapped_column(JSON)


class FoodRead(Base, SyncRecord):
    __tablename__ = "food_reads"
    __table_args__ = (UniqueConstraint("agenda_id", "member_id", name="uq_food_read_member"),)
    id: Mapped[UUID] = uuid_pk()
    agenda_id: Mapped[UUID] = mapped_column(ForeignKey("agendas.id", ondelete="CASCADE"), index=True, nullable=False)
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), nullable=False)
    read_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class Memo(Base, SyncRecord):
    __tablename__ = "memos"
    __table_args__ = (CheckConstraint("version > 0", name="ck_memo_version"),)
    id: Mapped[UUID] = uuid_pk()
    creator_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), nullable=False)
    title: Mapped[str | None] = mapped_column(String(200))
    content: Mapped[str] = mapped_column(Text, nullable=False)
    pinned: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    updated_by: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), nullable=False)


class Notice(Base, SyncRecord):
    __tablename__ = "notices"
    id: Mapped[UUID] = uuid_pk()
    publisher_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), index=True, nullable=False)
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    pinned: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)


class NoticeRead(Base, SyncRecord):
    __tablename__ = "notice_reads"
    __table_args__ = (UniqueConstraint("notice_id", "member_id", name="uq_notice_read_member"),)
    id: Mapped[UUID] = uuid_pk()
    notice_id: Mapped[UUID] = mapped_column(ForeignKey("notices.id", ondelete="CASCADE"), index=True, nullable=False)
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), nullable=False)
    read_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class LocationSnapshot(Base):
    __tablename__ = "location_snapshots"
    __table_args__ = (Index("ix_location_member_captured", "member_id", "captured_at"), CheckConstraint("latitude BETWEEN -90 AND 90", name="ck_location_latitude"), CheckConstraint("longitude BETWEEN -180 AND 180", name="ck_location_longitude"), CheckConstraint("horizontal_accuracy IS NULL OR horizontal_accuracy >= 0", name="ck_location_horizontal_accuracy"), CheckConstraint("source IS NULL OR source IN ('automatic', 'manual')", name="ck_location_source"))
    id: Mapped[UUID] = uuid_pk()
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), nullable=False)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    captured_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    event_type: Mapped[str | None] = mapped_column(String(32))
    horizontal_accuracy: Mapped[float | None] = mapped_column(Float)
    source: Mapped[str | None] = mapped_column(String(16))


class MemberPlace(Base, SyncRecord):
    __tablename__ = "member_places"
    __table_args__ = (Index("uq_enabled_home_per_member", "member_id", unique=True, postgresql_where=text("type = 'home' AND enabled AND deleted_at IS NULL")), Index("uq_enabled_school_per_member", "member_id", unique=True, postgresql_where=text("type = 'school' AND enabled AND deleted_at IS NULL")), CheckConstraint("type IN ('home', 'school', 'company', 'custom')", name="ck_place_type"), CheckConstraint("latitude BETWEEN -90 AND 90", name="ck_place_latitude"), CheckConstraint("longitude BETWEEN -180 AND 180", name="ck_place_longitude"), CheckConstraint("radius_m IN (100, 200, 500, 1000)", name="ck_place_radius"))
    id: Mapped[UUID] = uuid_pk()
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), index=True, nullable=False)
    type: Mapped[str] = mapped_column(String(32), nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    radius_m: Mapped[int] = mapped_column(Integer, nullable=False)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)


class GeofenceEvent(Base, SyncRecord):
    __tablename__ = "geofence_events"
    __table_args__ = (CheckConstraint("event_type IN ('arrive', 'leave')", name="ck_geofence_event_type"),)
    id: Mapped[UUID] = uuid_pk()
    place_id: Mapped[UUID] = mapped_column(ForeignKey("member_places.id", ondelete="CASCADE"), index=True, nullable=False)
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), nullable=False)
    event_type: Mapped[str] = mapped_column(String(16), nullable=False)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class ProcessedMutation(Base):
    __tablename__ = "processed_mutations"
    id: Mapped[UUID] = uuid_pk()
    mutation_id: Mapped[UUID] = mapped_column(PGUUID(as_uuid=True), unique=True, nullable=False)
    device_id: Mapped[UUID] = mapped_column(ForeignKey("devices.id", ondelete="RESTRICT"), index=True, nullable=False)
    result_json: Mapped[dict] = mapped_column(JSON, nullable=False)
    processed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class SyncChange(Base):
    __tablename__ = "sync_changes"
    __table_args__ = (Index("ix_sync_change_entity", "entity_type", "entity_id"),)
    # `seq` is assigned while holding the singleton SyncHead row lock. A
    # PostgreSQL sequence is deliberately not used here: sequences allocate
    # outside transaction commit order and can make a pull cursor skip a
    # change committed later by an earlier transaction.
    seq: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=False)
    entity_type: Mapped[str] = mapped_column(String(64), nullable=False)
    entity_id: Mapped[UUID] = mapped_column(PGUUID(as_uuid=True), nullable=False)
    operation: Mapped[str] = mapped_column(String(16), nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    payload: Mapped[dict | None] = mapped_column(JSON)
    source_mutation_id: Mapped[UUID | None] = mapped_column(PGUUID(as_uuid=True), unique=True)
    source_device_id: Mapped[UUID | None] = mapped_column(ForeignKey("devices.id", ondelete="SET NULL"), index=True)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class SyncHead(Base):
    """Singleton commit-ordered sync watermark (the row with id=1)."""
    __tablename__ = "sync_heads"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, default=1)
    committed_seq: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now(), onupdate=func.now())
