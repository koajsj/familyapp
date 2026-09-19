"""Pure scheduling rules for the future API; no ORM session or clock side effects."""
from datetime import date, timedelta

from ..errors import ValidationError


def week_number(day: date, week1_start: date, week1_end: date, total_weeks: int) -> int | None:
    """Match the iOS rule: custom first range, then seven-day weeks."""
    if total_weeks < 1 or week1_end < week1_start:
        return None
    if week1_start <= day <= week1_end:
        return 1
    second_start = week1_end + timedelta(days=1)
    if day < second_start:
        return None
    value = (day - second_start).days // 7 + 2
    return value if value <= total_weeks else None


def validate_schedule_weeks(start_week: int, end_week: int, total_weeks: int) -> None:
    if not 1 <= start_week <= end_week <= total_weeks:
        raise ValidationError("schedule weeks must be within the semester")


def validate_calendar_override(kind: str, mapped_weekday: int | None) -> None:
    if kind == "mappedWeekday" and mapped_weekday not in range(1, 8):
        raise ValidationError("mappedWeekday requires weekday 1...7")
    if kind != "mappedWeekday" and mapped_weekday is not None:
        raise ValidationError("mapped weekday is only allowed for mappedWeekday")
