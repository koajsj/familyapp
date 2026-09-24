"""Persistence queries for the registration control plane."""
from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ..models.entities import Device, Member, PendingRegistration


class RegistrationRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def registration(self, registration_id: UUID, *, lock: bool = False) -> PendingRegistration | None:
        statement = select(PendingRegistration).where(PendingRegistration.id == registration_id)
        if lock:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def applicant_registration(
        self, registration_id: UUID, installation_id: str, activation_token_hash: str, *, lock: bool = False,
    ) -> PendingRegistration | None:
        statement = select(PendingRegistration).where(
            PendingRegistration.id == registration_id,
            PendingRegistration.installation_id == installation_id,
            PendingRegistration.activation_token_hash == activation_token_hash,
        )
        if lock:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def active_member_for_normalized_name(self, normalized_name: str, *, lock: bool = False) -> Member | None:
        statement = select(Member).where(
            Member.normalized_display_name == normalized_name,
            Member.deleted_at.is_(None),
        )
        if lock:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def device_for_installation(self, installation_id: str) -> Device | None:
        return await self.session.scalar(select(Device).where(Device.installation_id == installation_id))

    async def expire_pending(self, now: datetime) -> None:
        """Resolve stale pending rows so partial unique indexes release them.

        Expiry is represented as a system rejection instead of inventing a
        fourth applicant-visible state. No member is created and no session
        can be issued for these rows.
        """
        await self.session.execute(
            update(PendingRegistration)
            .where(PendingRegistration.status == "pending", PendingRegistration.expires_at <= now)
            .values(status="rejected", decided_at=now)
        )

    async def reviewable(self, now: datetime) -> list[PendingRegistration]:
        await self.expire_pending(now)
        return list((await self.session.scalars(
            select(PendingRegistration)
            .where(PendingRegistration.status == "pending", PendingRegistration.expires_at > now)
            .order_by(PendingRegistration.created_at)
        )).all())
