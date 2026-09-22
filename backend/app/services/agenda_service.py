from datetime import datetime
from ..errors import ConflictError


def validate_timed_agenda(kind: str, start_at: datetime | None, end_at: datetime | None) -> None:
    if kind in {"normal", "exam"} and (start_at is None or end_at is None or start_at >= end_at):
        raise ConflictError("timed Agenda requires a positive half-open interval")
