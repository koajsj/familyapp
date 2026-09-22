"""Pure local-policy-compatible location rules; no GPS or geofence worker."""
from datetime import datetime, timedelta

from ..errors import ValidationError


ALLOWED_RADII = {100, 200, 500, 1000}
MEMBER_STATUSES = {"allGood", "headingHome", "atHome", "atSchool"}


def location_history_cutoff(now: datetime) -> datetime:
    return now - timedelta(days=30)


def validate_member_place(latitude: float, longitude: float, radius_m: int) -> None:
    if not -90 <= latitude <= 90 or not -180 <= longitude <= 180 or radius_m not in ALLOWED_RADII:
        raise ValidationError("invalid member place")


def validate_member_status(status: str, estimated_arrival: datetime | None) -> None:
    if status not in MEMBER_STATUSES:
        raise ValidationError("unknown member status")
    if (status == "headingHome") != (estimated_arrival is not None):
        raise ValidationError("estimated arrival is required only while heading home")
