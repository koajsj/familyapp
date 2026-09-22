"""One-use account recovery without mixing recovery tokens into normal auth."""
from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Literal
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from ..config import Settings
from ..errors import ConflictError, ForbiddenError, ValidationError
from ..member_identity import MEMBER_IDS
from ..models.entities import Member, RecoveryCredential, RecoverySession
from ..repositories.recovery import RecoveryRepository
from ..security import (
    hash_password,
    hash_recovery_secret,
    recovery_token,
    token_hash,
    verify_recovery_secret,
)
from .auth_service import AuthService

RecoveryPurpose = Literal["forgot_password", "new_device", "account_takeover"]


class RecoveryAttemptDenied(ForbiddenError):
    """A failed proof whose cooldown state must survive the HTTP error path."""


class RecoveryService:
    """Recovery control-plane operations, all completed in the request transaction."""
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.repository = RecoveryRepository(session)

    async def register_credential(self, member_id: UUID, recovery_secret: str) -> int:
        self._validate_secret(recovery_secret)
        now = datetime.now(UTC)
        credential = await self.repository.credential(member_id, lock=True)
        if credential is None:
            credential = RecoveryCredential(member_id=member_id, verifier=hash_recovery_secret(recovery_secret), generation=1)
            self.session.add(credential)
        else:
            credential.verifier = hash_recovery_secret(recovery_secret)
            credential.generation += 1
            credential.rotated_at = now
            credential.failed_attempts = 0
            credential.next_allowed_at = None
        await self.repository.invalidate_sessions(member_id, now)
        await self.session.flush()
        return credential.generation

    async def credential_status(self, member_id: UUID) -> int | None:
        credential = await self.repository.credential(member_id)
        return credential.generation if credential is not None else None

    async def begin(self, member_key: str, recovery_secret: str, purpose: RecoveryPurpose) -> tuple[RecoverySession, str]:
        self._validate_secret(recovery_secret)
        member = await self.repository.member_for_key(member_key)
        # Keep the response deliberately non-enumerating.  Member keys are
        # fixed, but whether recovery was configured is sensitive state.
        if member is None or member.id != MEMBER_IDS.get(member_key):
            raise RecoveryAttemptDenied("recovery is unavailable")
        now = datetime.now(UTC)
        credential = await self.repository.credential(member.id, lock=True)
        if credential is None:
            raise RecoveryAttemptDenied("recovery is unavailable")
        if credential.next_allowed_at is not None and credential.next_allowed_at > now:
            raise ConflictError("recovery_cooldown")
        if not verify_recovery_secret(recovery_secret, credential.verifier):
            credential.failed_attempts += 1
            # Exponential cooldown, capped at one hour. A correct recovery
            # secret resets this state; no permanent account lockout exists.
            delay = min(3_600, 2 ** min(12, credential.failed_attempts))
            credential.next_allowed_at = now + timedelta(seconds=delay)
            await self.session.flush()
            raise RecoveryAttemptDenied("recovery is unavailable")
        credential.failed_attempts = 0
        credential.next_allowed_at = None
        opaque = recovery_token()
        authorization = RecoverySession(
            member_id=member.id,
            token_hash=token_hash(opaque),
            purpose=purpose,
            recovery_generation=credential.generation,
            expires_at=now + timedelta(seconds=self.settings.recovery_session_ttl_seconds),
        )
        self.session.add(authorization)
        await self.session.flush()
        return authorization, opaque

    async def reset_password(self, recovery_session_id: UUID, token: str, new_password: str) -> None:
        authorization, member, _ = await self._consume(recovery_session_id, token, "forgot_password")
        self._validate_password(new_password)
        member.password_hash = hash_password(new_password)
        authorization.used_at = datetime.now(UTC)
        await self.session.flush()

    async def issue_new_device_session(
        self, recovery_session_id: UUID, token: str, installation_id: str,
    ) -> tuple[str, str, UUID]:
        authorization, member, _ = await self._consume(recovery_session_id, token, "new_device")
        tokens = await AuthService(self.session, self.settings).issue_session(member, installation_id)
        authorization.used_at = datetime.now(UTC)
        await self.session.flush()
        return tokens

    async def complete_takeover(
        self, recovery_session_id: UUID, token: str, new_password: str, installation_id: str,
        new_recovery_secret: str,
    ) -> tuple[str, str, UUID, int]:
        authorization, member, credential = await self._consume(recovery_session_id, token, "account_takeover")
        self._validate_password(new_password)
        self._validate_secret(new_recovery_secret)
        now = datetime.now(UTC)
        member.password_hash = hash_password(new_password)
        # Generation is the server-side kill switch for both the old mnemonic
        # and every outstanding recovery authorization.
        credential.verifier = hash_recovery_secret(new_recovery_secret)
        credential.generation += 1
        credential.rotated_at = now
        credential.failed_attempts = 0
        credential.next_allowed_at = None
        authorization.used_at = now
        await self.repository.invalidate_sessions(member.id, now)
        access, refresh, device_id = await AuthService(self.session, self.settings).issue_session(
            member, installation_id, reinstate_revoked_device=True, revoke_other_devices=True, now=now,
        )
        await self.session.flush()
        return access, refresh, device_id, credential.generation

    async def _consume(
        self, recovery_session_id: UUID, token: str, purpose: RecoveryPurpose,
    ) -> tuple[RecoverySession, Member, RecoveryCredential]:
        if not token or len(token) > 512:
            raise ForbiddenError("recovery authorization is invalid")
        authorization = await self.repository.session_for_token(token_hash(token), lock=True)
        now = datetime.now(UTC)
        if (
            authorization is None or authorization.id != recovery_session_id
            or authorization.purpose != purpose or authorization.used_at is not None
            or authorization.expires_at <= now
        ):
            raise ForbiddenError("recovery authorization is invalid")
        member = await self.session.get(Member, authorization.member_id, with_for_update=True)
        credential = await self.repository.credential(authorization.member_id, lock=True)
        if member is None or credential is None or credential.generation != authorization.recovery_generation:
            raise ForbiddenError("recovery authorization is invalid")
        return authorization, member, credential

    @staticmethod
    def _validate_password(value: str) -> None:
        if not 8 <= len(value) <= 256:
            raise ValidationError("password is invalid")

    @staticmethod
    def _validate_secret(value: str) -> None:
        # The iOS client sends 32 bytes of HKDF output as base64. The server
        # receives no mnemonic and never logs this value.
        if not 40 <= len(value) <= 512:
            raise ValidationError("recovery secret is invalid")
