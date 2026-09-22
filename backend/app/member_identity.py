"""Stable IDs for the three fixed FamilyApp members.

These values are part of the mobile/backend sync contract.  They are not
derived from display names, device installation IDs, or database insertion
order. Provisioning must create the corresponding `members` rows with these
primary keys before any remote login is enabled.
"""
from __future__ import annotations

from uuid import UUID


MEMBER_IDS: dict[str, UUID] = {
    "Sendai": UUID("e7fda0a8-08b2-5ee0-b4ef-fcd4a381591a"),
    "Osaka": UUID("62d93a27-bb70-57b4-8d10-c43e80f612d1"),
    "Kyoto": UUID("f24af69c-3fd8-59bc-ab96-0b2610a1a4e5"),
}

MEMBER_STATUS_IDS: dict[UUID, UUID] = {
    MEMBER_IDS["Sendai"]: UUID("1e0f6ad0-5b92-5ae3-9257-6e10948fb2e1"),
    MEMBER_IDS["Osaka"]: UUID("f61c09e6-43a5-5ee3-b413-595b4df7df88"),
    MEMBER_IDS["Kyoto"]: UUID("2b0d2442-1e9d-5fd4-bbd9-2d1f31859f9d"),
}

FAMILY_CHAT_ID = UUID("e6e4f080-93bd-5d58-a48d-1f18d1390217")
