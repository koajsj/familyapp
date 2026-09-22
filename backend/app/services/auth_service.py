"""Auth service with rotating opaque refresh tokens and per-device sessions."""
from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from ..config import Settings
from ..errors import ForbiddenError
from ..member_identity import MEMBER_IDS
from ..models.entities import Device, Member, RefreshSession
from ..repositories.auth import AuthRepository
from ..security import encode_access_token, refresh_token, token_hash, verify_password


class AuthService:
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.repository = AuthRepository(session)

    async def login(self, member_key: str, password: str, installation_id: str) -> tuple[str, str, UUID]:
        member = await self.repository.member_for_key(member_key)
        if member is None or member.id != MEMBER_IDS.get(member_key) or not verify_password(password, member.password_hash):
            raise ForbiddenError("invalid credentials")
        return await self.issue_session(member, installation_id)

    async def issue_session(
        self, member: Member, installation_id: str, *, reinstate_revoked_device: bool = False,
        revoke_other_devices: bool = False, now: datetime | None = None,
    ) -> tuple[str, str, UUID]:
        """Reuse the single Device + access/refresh issuance path for all auth flows."""
        current_time = now or datetime.now(UTC)
        device = await self.repository.device_for_installation(installation_id)
        if device is not None and device.member_id != member.id:
            raise ForbiddenError("installation belongs to another member")
        if device is None:
            device = await self.repository.create_device(member.id, installation_id, current_time)
        if device.revoked_at is not None:
            if not reinstate_revoked_device:
                raise ForbiddenError("device has been revoked")
            device.revoked_at = None
        if revoke_other_devices:
            await self.repository.revoke_member_devices_except(member.id, device.id, current_time)
            await self.repository.revoke_member_refresh_sessions(member.id, current_time)
        device.last_seen_at = current_time
        access = encode_access_token(member.id, device.id, self.settings.access_token_secret, self.settings.access_token_ttl_seconds)
        refresh = refresh_token()
        self.session.add(RefreshSession(member_id=member.id, device_id=device.id, token_hash=token_hash(refresh), expires_at=current_time + timedelta(seconds=self.settings.refresh_token_ttl_seconds)))
        await self.session.flush()
        return access, refresh, device.id


    async def rotate(self, presented_token: str) -> tuple[str, str, UUID]:
        # Lock the device before its refresh-session rows, matching the
        # explicit device-revocation path. Re-read the token under lock after
        # that boundary so a concurrent revoke always wins.
        presented_hash = token_hash(presented_token)
        current = await self.repository.refresh_session(presented_hash)
        now = datetime.now(UTC)
        if current is None or current.revoked_at is not None or current.expires_at <= now:
            raise ForbiddenError("refresh token is invalid")
        device = await self.repository.active_device(current.device_id, current.member_id, lock=True)
        if device is None:
            raise ForbiddenError("device has been revoked")
        current = await self.repository.refresh_session(presented_hash, lock=True)
        if current is None or current.revoked_at is not None or current.expires_at <= now:
            raise ForbiddenError("refresh token is invalid")
        replacement = refresh_token()
        next_session = RefreshSession(member_id=current.member_id, device_id=current.device_id, token_hash=token_hash(replacement), expires_at=now + timedelta(seconds=self.settings.refresh_token_ttl_seconds))
        self.session.add(next_session)
        await self.session.flush()
        current.revoked_at = now
        current.replaced_by_id = next_session.id
        access = encode_access_token(current.member_id, current.device_id, self.settings.access_token_secret, self.settings.access_token_ttl_seconds)
        return access, replacement, current.device_id

    async def revoke(self, presented_token: str) -> None:
        current = await self.repository.refresh_session(token_hash(presented_token))
        if current is not None and current.revoked_at is None:
            current.revoked_at = datetime.now(UTC)
