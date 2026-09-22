from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ..models.entities import Device, Member, RefreshSession


class AuthRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def member_for_key(self, member_key: str) -> Member | None:
        return await self.session.scalar(select(Member).where(Member.member_key == member_key, Member.deleted_at.is_(None)))

    async def device_for_installation(self, installation_id: str) -> Device | None:
        return await self.session.scalar(select(Device).where(Device.installation_id == installation_id))

    async def create_device(self, member_id: UUID, installation_id: str, now: datetime) -> Device:
        device = Device(member_id=member_id, installation_id=installation_id, last_seen_at=now)
        self.session.add(device)
        await self.session.flush()
        return device

    async def refresh_session(self, token_hash: str, *, lock: bool = False) -> RefreshSession | None:
        statement = select(RefreshSession).where(RefreshSession.token_hash == token_hash)
        if lock:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def active_device(self, device_id: UUID, member_id: UUID, *, lock: bool = False) -> Device | None:
        """Return an active device owned by ``member_id``.

        Refresh rotation is a security boundary: a refresh token must not
        outlive an explicit device revocation.  Lock both rows during rotation
        so a concurrent revocation cannot be bypassed by a stale ORM object.
        """
        statement = select(Device).where(
            Device.id == device_id,
            Device.member_id == member_id,
            Device.revoked_at.is_(None),
        )
        if lock:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def revoke_device_refresh_sessions(self, device_id: UUID, now: datetime) -> None:
        await self.session.execute(
            update(RefreshSession)
            .where(RefreshSession.device_id == device_id, RefreshSession.revoked_at.is_(None))
            .values(revoked_at=now)
        )

    async def revoke_member_devices_except(self, member_id: UUID, keep_device_id: UUID, now: datetime) -> None:
        await self.session.execute(
            update(Device)
            .where(Device.member_id == member_id, Device.id != keep_device_id, Device.revoked_at.is_(None))
            .values(revoked_at=now)
        )

    async def revoke_member_refresh_sessions(self, member_id: UUID, now: datetime) -> None:
        await self.session.execute(
            update(RefreshSession)
            .where(RefreshSession.member_id == member_id, RefreshSession.revoked_at.is_(None))
            .values(revoked_at=now)
        )
