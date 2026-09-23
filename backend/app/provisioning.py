"""Explicit, idempotent fixed-member provisioning for a future remote rollout.

It is invoked only by deploy/bootstrap.sh when REMOTE_SYNC_ENABLED=true. The
local-only iOS app never imports or calls this module.
"""
from __future__ import annotations

import asyncio
import os

from sqlalchemy import select

from .config import Settings
from .db import make_session_factory
from .member_identity import FAMILY_CHAT_ID, MEMBER_IDS
from .models.entities import Chat, Member
from .security import hash_password


async def provision() -> None:
    password = os.environ.get("FAMILYAPP_FIXED_MEMBER_PASSWORD", "")
    if len(password) < 8:
        raise RuntimeError("FAMILYAPP_FIXED_MEMBER_PASSWORD must be configured before remote auth provisioning")
    settings = Settings.from_environment()
    factory = make_session_factory(settings)
    async with factory() as session, session.begin():
        for member_key, member_id in MEMBER_IDS.items():
            existing = await session.get(Member, member_id)
            other = await session.scalar(select(Member).where(Member.member_key == member_key))
            if existing is not None and existing.member_key != member_key:
                raise RuntimeError("fixed member UUID is already bound to another member")
            if other is not None and other.id != member_id:
                raise RuntimeError("fixed member key is already bound to another UUID")
            if existing is None:
                session.add(Member(
                    id=member_id, member_key=member_key, display_name=member_key,
                    normalized_display_name=member_key.casefold(), is_initial_member=True,
                    password_hash=hash_password(password),
                ))
        if await session.get(Chat, FAMILY_CHAT_ID) is None:
            session.add(Chat(id=FAMILY_CHAT_ID))


if __name__ == "__main__":
    asyncio.run(provision())
