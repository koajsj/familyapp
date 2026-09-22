from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..member_identity import FAMILY_CHAT_ID
from ..models.entities import Chat, MediaAsset, Message


class MediaRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get(self, media_id: UUID) -> MediaAsset | None:
        return await self.session.scalar(select(MediaAsset).where(MediaAsset.id == media_id, MediaAsset.deleted_at.is_(None)))

    async def expired_pending(self, now: datetime) -> list[MediaAsset]:
        statement = select(MediaAsset).where(
            MediaAsset.deleted_at.is_(None),
            MediaAsset.status == "pending",
            MediaAsset.expires_at.is_not(None),
            MediaAsset.expires_at <= now,
        )
        return list((await self.session.scalars(statement)).all())

    async def active_object_keys(self) -> set[str]:
        statement = select(MediaAsset.object_key).where(MediaAsset.deleted_at.is_(None))
        return set((await self.session.scalars(statement)).all())

    async def ready_assets(self) -> list[MediaAsset]:
        statement = select(MediaAsset).where(
            MediaAsset.deleted_at.is_(None), MediaAsset.status == "ready"
        )
        return list((await self.session.scalars(statement)).all())

    async def has_active_family_chat_attachment(self, asset: MediaAsset) -> bool:
        """Return whether a finalized asset is attached to a visible family message.

        This deliberately follows the persisted ``Message.media_id`` foreign
        key instead of trusting a client-supplied chat or message identifier.
        A recalled/deleted message, a soft-deleted family chat, or an asset
        attached by somebody other than its uploader cannot grant access.
        """
        statement = (
            select(Message.id)
            .join(Chat, Message.chat_id == Chat.id)
            .where(
                Message.media_id == asset.id,
                Message.chat_id == FAMILY_CHAT_ID,
                Message.sender_id == asset.owner_id,
                Message.kind.in_(("image", "audio")),
                Message.deleted_at.is_(None),
                Message.recalled_at.is_(None),
                Chat.deleted_at.is_(None),
            )
            .limit(1)
        )
        return await self.session.scalar(statement) is not None
