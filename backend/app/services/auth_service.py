"""Auth service with rotating opaque refresh tokens and per-device sessions."""
from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from ..config import Settings
from ..errors import ForbiddenError
from ..models.entities import Device, Member, RefreshSession
from ..repositories.auth import AuthRepository
from ..security import encode_access_token, refresh_token, token_hash, verify_password


class AuthService:
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.repository = AuthRepository(session)

    async def login(self, member_key: str, password: str, installation_id: str, device_name: str | None = None) -> tuple[str, str, UUID]:
        member = await self.repository.member_for_login_identifier(member_key)
        if member is None or not verify_password(password, member.password_hash):
            raise ForbiddenError("invalid credentials")
        # Password reauthentication may restore this member's own revoked
        # installation, but bind_device always clears its location-source role.
        return await self.issue_session(
            member, installation_id, device_name=device_name,
            reinstate_revoked_device=True,
        )

    async def issue_session(
        self, member: Member, installation_id: str, *, reinstate_revoked_device: bool = False,
        revoke_other_devices: bool = False, revoke_current_device_sessions: bool = False,
        now: datetime | None = None, device_name: str | None = None,
    ) -> tuple[str, str, UUID]:
        """Reuse the single Device + access/refresh issuance path for all auth flows."""
        if member.deleted_at is not None:
            raise ForbiddenError("member is inactive")
        current_time = now or datetime.now(UTC)
        device = await self.bind_device(
            member, installation_id, reinstate_revoked_device=reinstate_revoked_device,
            now=current_time, device_name=device_name,
        )
        if revoke_other_devices:
            await self.repository.revoke_member_devices_except(member.id, device.id, current_time)
            await self.repository.revoke_member_refresh_sessions(member.id, current_time)
        elif revoke_current_device_sessions:
            # An applicant may retry activation after the server commits but
            # the client loses the response. Replace, never accumulate, the
            # current device's unknown refresh session in that recovery path.
            await self.repository.revoke_device_refresh_sessions(device.id, current_time)
        access = encode_access_token(member.id, device.id, self.settings.access_token_secret, self.settings.access_token_ttl_seconds)
        refresh = refresh_token()
        self.session.add(RefreshSession(member_id=member.id, device_id=device.id, token_hash=token_hash(refresh), expires_at=current_time + timedelta(seconds=self.settings.refresh_token_ttl_seconds)))
        await self.session.flush()
        return access, refresh, device.id

    async def bind_device(
        self, member: Member, installation_id: str, *, reinstate_revoked_device: bool = False,
        now: datetime | None = None, device_name: str | None = None,
    ) -> Device:
        """Create or bind the one installation record without issuing tokens.

        Registration approval uses this in the same transaction as Member
        creation. The applicant still needs to prove its activation capability
        before ``issue_session`` returns any normal credentials.
        """
        current_time = now or datetime.now(UTC)
        # Serialize issuance against the Member soft-delete lock. If departure
        # wins first no new session is possible; if issuance wins first the
        # removal transaction revokes the resulting device/session.
        if await self.repository.active_member(member.id, lock=True) is None:
            raise ForbiddenError("member is inactive")
        name = self._device_name(device_name)
        device = await self.repository.device_for_installation(installation_id)
        if device is not None and device.member_id != member.id:
            raise ForbiddenError("installation belongs to another member")
        if device is None:
            device = await self.repository.create_device(member.id, installation_id, name, current_time)
        if device.revoked_at is not None:
            if not reinstate_revoked_device:
                raise ForbiddenError("device has been revoked")
            # A restored installation must explicitly be selected again. This
            # avoids reactivating a historical source flag into conflict with
            # a source already active on another device.
            device.is_location_source = False
            device.revoked_at = None
        device.last_seen_at = current_time
        if device_name is not None:
            device.display_name = name
        await self.session.flush()
        return device

    @staticmethod
    def _device_name(value: str | None) -> str:
        if value is None:
            return "此设备"
        normalized = " ".join(value.split())
        if not 1 <= len(normalized) <= 128 or any(ord(character) < 32 for character in normalized):
            raise ForbiddenError("device name is invalid")
        return normalized


    async def rotate(self, presented_token: str) -> tuple[str, str, UUID]:
        # Lock member -> device -> refresh session, matching member removal
        # and authenticated requests. The opposite order can deadlock with
        # a removal that holds the member row while revoking its devices.
        presented_hash = token_hash(presented_token)
        current = await self.repository.refresh_session(presented_hash)
        now = datetime.now(UTC)
        if current is None or current.revoked_at is not None or current.expires_at <= now:
            raise ForbiddenError("refresh token is invalid")
        if await self.repository.active_member(current.member_id, lock=True) is None:
            raise ForbiddenError("member is inactive")
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

    async def devices(self, member_id: UUID) -> list[Device]:
        if await self.repository.active_member(member_id) is None:
            raise ForbiddenError("member is inactive")
        return await self.repository.devices_for_member(member_id)

    async def revoke_device(self, member_id: UUID, device_id: UUID) -> None:
        """Revoke one owned device and only its refresh sessions."""
        device = await self.repository.device_for_member(device_id, member_id, lock=True)
        if device is None:
            raise ForbiddenError("device ownership required")
        if device.revoked_at is None:
            now = datetime.now(UTC)
            device.revoked_at = now
            await self.repository.revoke_device_refresh_sessions(device.id, now)

    async def revoke_other_devices(self, member_id: UUID, current_device_id: UUID) -> list[UUID]:
        # Lock the member first to serialize this active-device set with new
        # device binding before HTTP closes its corresponding WebSockets.
        if await self.repository.active_member(member_id, lock=True) is None:
            raise ForbiddenError("member is inactive")
        current = await self.repository.active_device(current_device_id, member_id, lock=True)
        if current is None:
            raise ForbiddenError("current device is unavailable")
        now = datetime.now(UTC)
        revoked_ids = await self.repository.active_device_ids_except(member_id, current_device_id, lock=True)
        await self.repository.revoke_member_devices_except(member_id, current_device_id, now)
        await self.repository.revoke_member_refresh_sessions_except_device(member_id, current_device_id, now)
        return revoked_ids

    async def select_location_source(self, member_id: UUID, current_device_id: UUID) -> None:
        # Locking the Member serializes source switches across devices.
        if await self.repository.active_member(member_id, lock=True) is None:
            raise ForbiddenError("member is inactive")
        if await self.repository.active_device(current_device_id, member_id, lock=True) is None:
            raise ForbiddenError("current device is unavailable")
        try:
            await self.repository.select_location_source(member_id, current_device_id)
        except LookupError as caught_error:
            raise ForbiddenError("current device is unavailable") from caught_error
