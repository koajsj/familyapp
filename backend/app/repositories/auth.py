from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ..models.entities import Device, Member, RefreshSession


class AuthRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def member_for_login_identifier(self, identifier: str) -> Member | None:
        """Resolve legacy member keys and active normalized display names."""
        return await self.session.scalar(select(Member).where(
            Member.deleted_at.is_(None),
            or_(
                Member.member_key == identifier,
                Member.normalized_display_name == self.normalize_login_identifier(identifier),
            ),
        ))

    @staticmethod
    def normalize_login_identifier(value: str) -> str:
        import re
        import unicodedata
        return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", value).strip()).casefold()

    async def active_member(self, member_id: UUID, *, lock: bool = False) -> Member | None:
        statement = select(Member).where(Member.id == member_id, Member.deleted_at.is_(None))
        if lock:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def device_for_installation(self, installation_id: str) -> Device | None:
        return await self.session.scalar(select(Device).where(Device.installation_id == installation_id))

    async def create_device(self, member_id: UUID, installation_id: str, display_name: str, now: datetime) -> Device:
        device = Device(member_id=member_id, installation_id=installation_id, display_name=display_name, last_seen_at=now)
        self.session.add(device)
        await self.session.flush()
        return device

    async def refresh_session(self, token_hash: str, *, lock: bool = False) -> RefreshSession | None:
        statement = select(RefreshSession).where(RefreshSession.token_hash == token_hash)
        if lock:
            statement = statement.with_for_update().execution_options(populate_existing=True)
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

    async def devices_for_member(self, member_id: UUID) -> list[Device]:
        return list((await self.session.scalars(
            select(Device)
            .where(Device.member_id == member_id, Device.revoked_at.is_(None))
            .order_by(Device.last_seen_at.desc())
        )).all())

    async def active_device_ids_except(self, member_id: UUID, keep_device_id: UUID, *, lock: bool = False) -> list[UUID]:
        statement = select(Device.id).where(
            Device.member_id == member_id,
            Device.id != keep_device_id,
            Device.revoked_at.is_(None),
        )
        if lock:
            statement = statement.with_for_update()
        return list((await self.session.scalars(statement)).all())

    async def device_for_member(self, device_id: UUID, member_id: UUID, *, lock: bool = False) -> Device | None:
        statement = select(Device).where(Device.id == device_id, Device.member_id == member_id)
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

    async def revoke_member_devices(self, member_id: UUID, now: datetime) -> None:
        await self.session.execute(
            update(Device)
            .where(Device.member_id == member_id, Device.revoked_at.is_(None))
            .values(revoked_at=now)
        )

    async def revoke_member_refresh_sessions(self, member_id: UUID, now: datetime) -> None:
        await self.session.execute(
            update(RefreshSession)
            .where(RefreshSession.member_id == member_id, RefreshSession.revoked_at.is_(None))
            .values(revoked_at=now)
        )

    async def revoke_member_refresh_sessions_except_device(self, member_id: UUID, keep_device_id: UUID, now: datetime) -> None:
        await self.session.execute(
            update(RefreshSession)
            .where(
                RefreshSession.member_id == member_id,
                RefreshSession.device_id != keep_device_id,
                RefreshSession.revoked_at.is_(None),
            )
            .values(revoked_at=now)
        )

    async def select_location_source(self, member_id: UUID, device_id: UUID) -> None:
        """Select exactly one active source while the member lock is held.

        The caller locks the Member row first.  That gives competing device
        settings requests one serialization boundary; the partial unique index
        remains the database backstop if a future path omits that lock.
        """
        await self.session.execute(
            update(Device)
            .where(Device.member_id == member_id, Device.revoked_at.is_(None))
            .values(is_location_source=False)
        )
        result = await self.session.execute(
            update(Device)
            .where(
                Device.id == device_id,
                Device.member_id == member_id,
                Device.revoked_at.is_(None),
            )
            .values(is_location_source=True)
        )
        if result.rowcount != 1:
            raise LookupError("active device not found")
