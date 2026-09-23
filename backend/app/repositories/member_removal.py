"""Persistence queries for the non-replicated member-removal control plane."""
from __future__ import annotations

from uuid import UUID

from datetime import datetime

from sqlalchemy import or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ..models.entities import Member, MemberRemovalRequest


class MemberRemovalRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def active_member(self, member_id: UUID, *, lock: bool = False) -> Member | None:
        statement = select(Member).where(Member.id == member_id, Member.deleted_at.is_(None))
        if lock:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def request(self, request_id: UUID, *, lock: bool = False) -> MemberRemovalRequest | None:
        statement = select(MemberRemovalRequest).where(MemberRemovalRequest.id == request_id)
        if lock:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def pending_for_target(self, target_member_id: UUID) -> MemberRemovalRequest | None:
        return await self.session.scalar(select(MemberRemovalRequest).where(
            MemberRemovalRequest.target_member_id == target_member_id,
            MemberRemovalRequest.status == "pending",
        ))

    async def reviewable(self) -> list[MemberRemovalRequest]:
        statement = select(MemberRemovalRequest).where(
            MemberRemovalRequest.status == "pending"
        ).order_by(MemberRemovalRequest.created_at)
        return list((await self.session.scalars(statement)).all())

    async def cancel_pending_for_member(self, member_id: UUID, now: datetime) -> None:
        """A departed requester or target cannot leave an actionable request."""
        await self.session.execute(
            update(MemberRemovalRequest)
            .where(
                MemberRemovalRequest.status == "pending",
                or_(
                    MemberRemovalRequest.target_member_id == member_id,
                    MemberRemovalRequest.requester_id == member_id,
                ),
            )
            .values(status="cancelled", decided_at=now)
        )
