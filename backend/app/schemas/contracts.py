"""Pydantic request/response contracts. Scaffold only; no route is live."""
from datetime import date, datetime
from typing import Any, Generic, Literal, TypeVar
from uuid import UUID

from pydantic import BaseModel, Field, model_validator

T = TypeVar("T")


class Page(BaseModel, Generic[T]):
    items: list[T]
    next_cursor: str | None = None


class ErrorBody(BaseModel):
    code: str
    message: str
    details: dict[str, Any] | None = None


class MemberOut(BaseModel):
    id: UUID
    display_name: str


class AuthLoginIn(BaseModel):
    member_id: UUID
    password: str = Field(min_length=1, max_length=256)


class TokenOut(BaseModel):
    access_token: str
    token_type: Literal["bearer"] = "bearer"


class MessageIn(BaseModel):
    kind: Literal["text", "image", "audio"]
    body: str | None = Field(default=None, max_length=10_000)
    media_key: str | None = Field(default=None, max_length=512)
    reply_to_id: UUID | None = None


class AgendaDraftIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    kind: Literal["normal", "exam", "assignmentDeadline", "orderFood"]
    participant_ids: list[UUID] = Field(min_length=1)
    start_at: datetime | None = None
    end_at: datetime | None = None
    due_at: datetime | None = None
    recurrence: dict[str, Any] | None = None

    @model_validator(mode="after")
    def valid_interval(self) -> "AgendaDraftIn":
        if self.kind in {"normal", "exam"} and (self.start_at is None or self.end_at is None or self.start_at >= self.end_at):
            raise ValueError("normal and exam agendas require [start_at, end_at)")
        if self.kind == "assignmentDeadline" and self.due_at is None:
            raise ValueError("assignment deadline requires due_at")
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
        if self.kind == "mappedWeekday" and self.mapped_weekday is None:
            raise ValueError("mappedWeekday requires mapped_weekday")
        if self.kind != "mappedWeekday" and self.mapped_weekday is not None:
            raise ValueError("mapped_weekday is only valid for mappedWeekday")
        return self


class NoticeDraftIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    content: str = Field(max_length=10_000)
    pinned: bool = False


class MemberPlaceIn(BaseModel):
    type: Literal["home", "school", "custom"]
    name: str = Field(min_length=1, max_length=120)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    radius_m: Literal[100, 200, 500, 1000]
    enabled: bool = True
