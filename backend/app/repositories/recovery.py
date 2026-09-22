"""Persistence helpers for the non-replicated account-recovery control plane."""
from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ..models.entities import Member, RecoveryCredential, RecoverySession


class RecoveryRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def member_for_key(self, member_key: str) -> Member | None:
        return await self.session.scalar(
            select(Member).where(Member.member_key == member_key, Member.deleted_at.is_(None))
        )

    async def credential(self, member_id: UUID, *, lock: bool = False) -> RecoveryCredential | None:
        statement = select(RecoveryCredential).where(RecoveryCredential.member_id == member_id)
        if lock:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def session_for_token(self, token_hash: str, *, lock: bool = False) -> RecoverySession | None:
        statement = select(RecoverySession).where(RecoverySession.token_hash == token_hash)
        if lock:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def invalidate_sessions(self, member_id: UUID, now: datetime) -> None:
        """Used sessions are retained for audit/idempotency boundaries, but unusable."""
        await self.session.execute(
            update(RecoverySession)
            .where(RecoverySession.member_id == member_id, RecoverySession.used_at.is_(None))
            .values(used_at=now)
        )
