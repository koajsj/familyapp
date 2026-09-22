"""Wire DTOs. Dates are civil dates; all datetimes are UTC-aware timestamps."""
from __future__ import annotations

from datetime import date, datetime
from typing import Any, Generic, Literal, TypeVar
from uuid import UUID

from pydantic import BaseModel, Field, model_validator

T = TypeVar("T")


class ErrorBody(BaseModel):
    code: str
    message: str
    details: dict[str, Any] | None = None


class Page(BaseModel, Generic[T]):
    items: list[T]
    next_cursor: str | None = None


class AuthLoginIn(BaseModel):
    member_key: Literal["Sendai", "Osaka", "Kyoto"]
    password: str = Field(min_length=1, max_length=256)
    installation_id: str = Field(min_length=8, max_length=128)


class RefreshIn(BaseModel):
    refresh_token: str = Field(min_length=32, max_length=512)


class TokenPairOut(BaseModel):
    access_token: str
    refresh_token: str
    token_type: Literal["bearer"] = "bearer"
    expires_in: int = Field(gt=0)
    device_id: UUID


class RecoveryCredentialIn(BaseModel):
    """Client-derived secret, never the human-readable mnemonic."""
    recovery_secret: str = Field(min_length=40, max_length=512)


class RecoveryCredentialOut(BaseModel):
    generation: int = Field(ge=1)


class RecoveryCredentialStatusOut(BaseModel):
    configured: bool
    generation: int | None = Field(default=None, ge=1)


class RecoveryStartIn(RecoveryCredentialIn):
    member_key: Literal["Sendai", "Osaka", "Kyoto"]
    purpose: Literal["forgot_password", "new_device", "account_takeover"]


class RecoverySessionOut(BaseModel):
    recovery_session_id: UUID
    recovery_token: str
    purpose: Literal["forgot_password", "new_device", "account_takeover"]
    expires_at: datetime
    recovery_generation: int = Field(ge=1)


class RecoveryCompletionIn(BaseModel):
    recovery_token: str = Field(min_length=32, max_length=512)


class RecoveryPasswordResetIn(RecoveryCompletionIn):
    new_password: str = Field(min_length=8, max_length=256)


class RecoveryDeviceSessionIn(RecoveryCompletionIn):
    installation_id: str = Field(min_length=8, max_length=128)


class RecoveryTakeoverIn(BaseModel):
    recovery_token: str = Field(min_length=32, max_length=512)
    installation_id: str = Field(min_length=8, max_length=128)
    recovery_secret: str = Field(min_length=40, max_length=512)
    new_password: str = Field(min_length=8, max_length=256)


class MemberOut(BaseModel):
    id: UUID
    member_key: Literal["Sendai", "Osaka", "Kyoto"]
    display_name: str
    version: int


class MemberStatusIn(BaseModel):
    status: Literal["allGood", "headingHome", "atHome", "atSchool"]
    estimated_arrival: datetime | None = None

    @model_validator(mode="after")
    def valid_arrival(self) -> "MemberStatusIn":
        if (self.status == "headingHome") != (self.estimated_arrival is not None):
            raise ValueError("estimated_arrival is required only while headingHome")
        return self


class ScheduleDraftIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    kind: Literal["course", "groupMeeting"]
    weekday: int = Field(ge=1, le=7)
    start_minutes: int = Field(ge=0, le=1439)
    end_minutes: int = Field(ge=1, le=1440)
    start_week: int = Field(ge=1)
    end_week: int = Field(ge=1)
    week_type: Literal["everyWeek", "oddWeek", "evenWeek"]
    metadata: dict[str, Any] = Field(default_factory=dict)

    @model_validator(mode="after")
    def valid_range(self) -> "ScheduleDraftIn":
        if self.start_minutes >= self.end_minutes or self.start_week > self.end_week:
            raise ValueError("schedule range is invalid")
        return self


class SemesterIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    week1_start: date
    week1_end: date
    total_weeks: int = Field(ge=1, le=52)

    @model_validator(mode="after")
    def valid_week_one(self) -> "SemesterIn":
        if self.week1_end < self.week1_start:
            raise ValueError("week1_end must not precede week1_start")
        return self


class CalendarOverrideIn(BaseModel):
    date: date
    kind: Literal["holiday", "normal", "mappedWeekday"]
    mapped_weekday: int | None = Field(default=None, ge=1, le=7)
    note: str | None = Field(default=None, max_length=2_000)

    @model_validator(mode="after")
    def valid_mapping(self) -> "CalendarOverrideIn":
        if (self.kind == "mappedWeekday") != (self.mapped_weekday is not None):
            raise ValueError("mapped_weekday is required only for mappedWeekday")
        return self


class AgendaDraftIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    kind: Literal["normal", "exam", "assignmentDeadline", "orderFood"]
    participant_ids: list[UUID] = Field(min_length=1)
    start_at: datetime | None = None
    end_at: datetime | None = None
    due_at: datetime | None = None
    recurrence: dict[str, Any] | None = None
    detail: dict[str, Any] = Field(default_factory=dict)

    @model_validator(mode="after")
    def valid_interval(self) -> "AgendaDraftIn":
        if len(set(self.participant_ids)) != len(self.participant_ids):
            raise ValueError("participant_ids must be unique")
        if self.kind in {"normal", "exam"} and (self.start_at is None or self.end_at is None or self.start_at >= self.end_at):
            raise ValueError("timed agendas require [start_at, end_at)")
        if self.kind == "assignmentDeadline" and self.due_at is None:
            raise ValueError("assignment deadline requires due_at")
        return self


class NoticeDraftIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    content: str = Field(max_length=10_000)
    pinned: bool = False


class MemberPlaceIn(BaseModel):
    type: Literal["home", "school", "company", "custom"]
    name: str = Field(min_length=1, max_length=120)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    radius_m: Literal[100, 200, 500, 1000]
    enabled: bool = True


class MutationIn(BaseModel):
    mutation_id: UUID
    entity_type: str = Field(min_length=1, max_length=64)
    entity_id: UUID
    operation: Literal["create", "update", "delete", "upsert"]
    base_version: int | None = Field(default=None, ge=0)
    payload: dict[str, Any] = Field(default_factory=dict)
    client_timestamp: datetime


class PushIn(BaseModel):
    device_id: UUID
    mutations: list[MutationIn] = Field(min_length=1, max_length=200)


class MutationAck(BaseModel):
    mutation_id: UUID
    entity_type: str
    entity_id: UUID
    operation: str
    version: int
    seq: int
    duplicate: bool = False


class MutationConflict(BaseModel):
    mutation_id: UUID
    entity_type: str
    entity_id: UUID
    code: Literal["version_conflict", "tombstone_conflict"]
    current_version: int
    current_payload: dict[str, Any] | None = None


class PushOut(BaseModel):
    applied: list[MutationAck]
    conflicts: list[MutationConflict]
    latest_cursor: int


class SyncChangeOut(BaseModel):
    seq: int
    entity_type: str
    entity_id: UUID
    operation: Literal["create", "update", "delete", "upsert"]
    version: int
    updated_at: datetime
    payload: dict[str, Any] | None = None
    source_mutation_id: UUID | None = None
    source_device_id: UUID | None = None


class PullOut(BaseModel):
    changes: list[SyncChangeOut]
    latest_cursor: int
    has_more: bool


class BootstrapOut(BaseModel):
    entities: dict[str, list[dict[str, Any]]]
    latest_cursor: int
    family_timezone: str


class ImportBatchRollbackIn(BaseModel):
    mutation_id: UUID
    expected_version: int = Field(ge=1)


class ImportBatchRollbackOut(BaseModel):
    mutation_id: UUID
    batch_id: UUID
    version: int
    latest_cursor: int
    duplicate: bool = False


class MediaCreateIn(BaseModel):
    # The iOS transfer record allocates this stable ID before asking for a
    # grant, so an interrupted request can be retried without a second asset.
    media_id: UUID
    mime_type: str = Field(min_length=3, max_length=128)
    size_bytes: int = Field(ge=0, le=100_000_000)
    checksum: str = Field(pattern=r"^[A-Fa-f0-9]{64}$")


class MediaUploadOut(BaseModel):
    media_id: UUID
    object_key: str
    upload_url: str | None = None
    upload_headers: dict[str, str] = Field(default_factory=dict)
    status: Literal["pending", "ready", "missing"]


class MediaFinalizeIn(BaseModel):
    checksum: str = Field(pattern=r"^[A-Fa-f0-9]{64}$")


class MediaDownloadOut(BaseModel):
    media_id: UUID
    download_url: str
    expires_in: int = Field(gt=0)
