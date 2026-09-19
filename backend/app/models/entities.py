"""SQLAlchemy persistence draft for the future remote repository.

Scaffold only: importing this module defines metadata but never opens a
database connection. iOS continues to use LocalRepository.
"""
from __future__ import annotations

from datetime import date, datetime
from uuid import UUID, uuid4

from sqlalchemy import Boolean, Date, DateTime, Float, ForeignKey, Index, Integer, JSON, String, Text, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


def uuid_pk() -> Mapped[UUID]:
    return mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid4)


class Member(Base):
    __tablename__ = "members"
    id: Mapped[UUID] = uuid_pk()
    display_name: Mapped[str] = mapped_column(String(80), nullable=False)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)


class AuthSession(Base):
    __tablename__ = "auth_sessions"
    id: Mapped[UUID] = uuid_pk()
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), index=True, nullable=False)
    token_hash: Mapped[str] = mapped_column(String(255), unique=True, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class Chat(Base):
    __tablename__ = "chats"
    id: Mapped[UUID] = uuid_pk()
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)


class Message(Base):
    __tablename__ = "messages"
    id: Mapped[UUID] = uuid_pk()
    chat_id: Mapped[UUID] = mapped_column(ForeignKey("chats.id", ondelete="CASCADE"), index=True, nullable=False)
    sender_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), index=True, nullable=False)
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    body: Mapped[str | None] = mapped_column(Text)
    media_key: Mapped[str | None] = mapped_column(String(512))
    reply_to_id: Mapped[UUID | None] = mapped_column(ForeignKey("messages.id", ondelete="SET NULL"))
    sent_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    recalled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class MessageReceipt(Base):
    __tablename__ = "message_receipts"
    __table_args__ = (UniqueConstraint("message_id", "member_id", name="uq_message_receipt_member"),)
    id: Mapped[UUID] = uuid_pk()
    message_id: Mapped[UUID] = mapped_column(ForeignKey("messages.id", ondelete="CASCADE"), index=True, nullable=False)
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), nullable=False)
    delivered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Semester(Base):
    __tablename__ = "semesters"
    id: Mapped[UUID] = uuid_pk()
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    week1_start: Mapped[date] = mapped_column(Date, nullable=False)
    week1_end: Mapped[date] = mapped_column(Date, nullable=False)
    total_weeks: Mapped[int] = mapped_column(Integer, nullable=False)
    is_current: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)


class Schedule(Base):
    __tablename__ = "schedules"
    __table_args__ = (Index("ix_schedule_owner_semester", "owner_id", "semester_id"),)
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
    metadata_json: Mapped[dict] = mapped_column(JSON, default=dict, nullable=False)


class ScheduleException(Base):
    __tablename__ = "schedule_exceptions"
    id: Mapped[UUID] = uuid_pk()
    schedule_id: Mapped[UUID] = mapped_column(ForeignKey("schedules.id", ondelete="CASCADE"), index=True, nullable=False)
    scope: Mapped[str] = mapped_column(String(32), nullable=False)
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    occurrence_date: Mapped[date] = mapped_column(Date, nullable=False)
    replacement_json: Mapped[dict | None] = mapped_column(JSON)


class CalendarOverride(Base):
    __tablename__ = "calendar_overrides"
    __table_args__ = (UniqueConstraint("semester_id", "date", name="uq_calendar_override_day"),)
    id: Mapped[UUID] = uuid_pk()
    semester_id: Mapped[UUID] = mapped_column(ForeignKey("semesters.id", ondelete="CASCADE"), index=True, nullable=False)
    date: Mapped[date] = mapped_column(Date, nullable=False)
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    mapped_weekday: Mapped[int | None] = mapped_column(Integer)
    note: Mapped[str | None] = mapped_column(Text)


class Agenda(Base):
    __tablename__ = "agendas"
    id: Mapped[UUID] = uuid_pk()
    creator_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), index=True, nullable=False)
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    start_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    end_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    participant_ids: Mapped[list] = mapped_column(JSON, default=list, nullable=False)
    recurrence_rule: Mapped[dict | None] = mapped_column(JSON)
    detail_json: Mapped[dict] = mapped_column(JSON, default=dict, nullable=False)


class AgendaException(Base):
    __tablename__ = "agenda_exceptions"
    id: Mapped[UUID] = uuid_pk()
    agenda_id: Mapped[UUID] = mapped_column(ForeignKey("agendas.id", ondelete="CASCADE"), index=True, nullable=False)
    scope: Mapped[str] = mapped_column(String(32), nullable=False)
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    occurrence_date: Mapped[date] = mapped_column(Date, nullable=False)
    replacement_json: Mapped[dict | None] = mapped_column(JSON)


class Memo(Base):
    __tablename__ = "memos"
    id: Mapped[UUID] = uuid_pk()
    creator_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    updated_by: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), nullable=False)


class Notice(Base):
    __tablename__ = "notices"
    id: Mapped[UUID] = uuid_pk()
    publisher_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="RESTRICT"), index=True, nullable=False)
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    pinned: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)


class NoticeRead(Base):
    __tablename__ = "notice_reads"
    __table_args__ = (UniqueConstraint("notice_id", "member_id", name="uq_notice_read_member"),)
    id: Mapped[UUID] = uuid_pk()
    notice_id: Mapped[UUID] = mapped_column(ForeignKey("notices.id", ondelete="CASCADE"), index=True, nullable=False)
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), nullable=False)
    read_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)


class LocationSnapshot(Base):
    __tablename__ = "location_snapshots"
    __table_args__ = (Index("ix_location_member_captured", "member_id", "captured_at"),)
    id: Mapped[UUID] = uuid_pk()
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), nullable=False)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    captured_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    event_type: Mapped[str | None] = mapped_column(String(32))


class MemberPlace(Base):
    __tablename__ = "member_places"
    id: Mapped[UUID] = uuid_pk()
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), index=True, nullable=False)
    type: Mapped[str] = mapped_column(String(32), nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    radius_m: Mapped[int] = mapped_column(Integer, nullable=False)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)


class GeofenceEvent(Base):
    __tablename__ = "geofence_events"
    id: Mapped[UUID] = uuid_pk()
    place_id: Mapped[UUID] = mapped_column(ForeignKey("member_places.id", ondelete="CASCADE"), index=True, nullable=False)
    member_id: Mapped[UUID] = mapped_column(ForeignKey("members.id", ondelete="CASCADE"), nullable=False)
    event_type: Mapped[str] = mapped_column(String(16), nullable=False)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
