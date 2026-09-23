"""Invitation-gated registration and member approval control plane.

Pending applications have no bearer session and are deliberately absent from
the sync graph. A normal member appears only after an authenticated approver
commits the decision.
"""
from __future__ import annotations

import hmac
import re
import unicodedata
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import Settings
from ..errors import ConflictError, ForbiddenError, NotFoundError, ValidationError
from ..models.entities import Member, PendingRegistration
from ..repositories.registration import RegistrationRepository
from ..repositories.sync import SyncRepository
from ..security import hash_password, refresh_token, token_hash
from .auth_service import AuthService
from .sync_service import SyncService


class RegistrationService:
    _ACTIVATION_REPLAY_WINDOW = timedelta(minutes=2)
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.repository = RegistrationRepository(session)

    async def submit(
        self, *, display_name: str, password: str, invite_code: str, installation_id: str,
    ) -> tuple[PendingRegistration, str]:
        """Create only an application after constant-time server invite proof."""
        self._validate_password(password)
        self._validate_installation_id(installation_id)
        visible_name, normalized_name = self._normalize_display_name(display_name)
        if not hmac.compare_digest(invite_code, self.settings.invite_code):
            raise ForbiddenError("invalid invite code")
        now = datetime.now(UTC)
        await self.repository.expire_pending(now)
        if await self.repository.active_member_for_normalized_name(normalized_name):
            raise ConflictError("display_name_unavailable")
        if await self.repository.device_for_installation(installation_id):
            # A registration may not borrow an installation bound to a real
            # account, even if the caller knows the invite code.
            raise ConflictError("installation_unavailable")
        opaque = refresh_token()
        registration = PendingRegistration(
            display_name=visible_name,
            normalized_display_name=normalized_name,
            password_hash=hash_password(password),
            installation_id=installation_id,
            activation_token_hash=token_hash(opaque),
            status="pending",
            expires_at=now + timedelta(seconds=self.settings.pending_registration_ttl_seconds),
        )
        try:
            async with self.session.begin_nested():
                self.session.add(registration)
                await self.session.flush()
        except IntegrityError as caught_error:
            # PostgreSQL partial unique indexes serialize competing pending
            # applications even when two requests pass the preflight together.
            raise ConflictError("registration_already_pending") from caught_error
        return registration, opaque

    async def applicant_status(
        self, registration_id: UUID, installation_id: str, activation_token: str,
    ) -> PendingRegistration:
        registration = await self._applicant_registration(
            registration_id, installation_id, activation_token, lock=True,
        )
        await self._expire_if_needed(registration, datetime.now(UTC))
        await self.session.flush()
        return registration

    async def cancel(
        self, registration_id: UUID, installation_id: str, activation_token: str,
    ) -> PendingRegistration:
        registration = await self._applicant_registration(
            registration_id, installation_id, activation_token, lock=True,
        )
        now = datetime.now(UTC)
        await self._expire_if_needed(registration, now)
        if registration.status == "pending":
            registration.status = "rejected"
            registration.decided_at = now
        elif registration.status != "rejected":
            raise ConflictError("registration_not_cancellable")
        await self.session.flush()
        return registration

    async def reviewable(self) -> list[PendingRegistration]:
        return await self.repository.reviewable(datetime.now(UTC))

    async def decide(
        self, registration_id: UUID, approver_id: UUID, decision: str,
    ) -> tuple[PendingRegistration, int | None]:
        """Approve or reject once, with member creation and SyncChange atomic."""
        if decision not in {"approved", "rejected"}:
            raise ValidationError("registration decision is invalid")
        registration = await self.repository.registration(registration_id, lock=True)
        if registration is None:
            raise NotFoundError("registration not found")
        now = datetime.now(UTC)
        await self._expire_if_needed(registration, now)
        if registration.status == "approved":
            # Idempotent approval returns the original decision without a
            # second Member, Device, refresh token, or sync change.
            if decision == "approved":
                return registration, None
            raise ConflictError("registration_already_decided")
        if registration.status == "rejected":
            if decision == "rejected":
                return registration, None
            raise ConflictError("registration_already_decided")

        if decision == "rejected":
            registration.status = "rejected"
            registration.rejected_by = approver_id
            registration.decided_at = now
            await self.session.flush()
            return registration, None

        # Validate every precondition before changing any managed record. The
        # active-member partial unique index closes concurrent-approval races.
        if await self.repository.active_member_for_normalized_name(
            registration.normalized_display_name, lock=True,
        ):
            raise ConflictError("display_name_unavailable")
        if await self.repository.device_for_installation(registration.installation_id):
            raise ConflictError("installation_unavailable")

        member_id = uuid4()
        member = Member(
            id=member_id,
            member_key=str(member_id).lower(),
            display_name=registration.display_name,
            normalized_display_name=registration.normalized_display_name,
            is_initial_member=False,
            password_hash=registration.password_hash,
        )
        try:
            # The savepoint leaves the outer request transaction usable when
            # PostgreSQL's active-member unique index wins a concurrent race.
            async with self.session.begin_nested():
                self.session.add(member)
                registration.status = "approved"
                registration.member_id = member.id
                registration.approved_by = approver_id
                registration.decided_at = now
                await self.session.flush()
        except IntegrityError as caught_error:
            raise ConflictError("display_name_unavailable") from caught_error

        # Bind exactly the applying installation before publishing the Member.
        # This creates no normal session: only the applicant's later activation
        # proof may enter AuthService.issue_session and receive token material.
        await AuthService(self.session, self.settings).bind_device(
            member, registration.installation_id, now=now,
        )

        change = await SyncRepository(self.session).append_change(
            "member", member.id, "create", member.version,
            SyncService._serialize(member),
        )
        await self.session.flush()
        return registration, change.seq

    async def activate(
        self, registration_id: UUID, installation_id: str, activation_token: str, device_name: str | None = None,
    ) -> tuple[PendingRegistration, tuple[str, str, UUID]]:
        """Turn an approved, installation-bound request into the normal session.

        Tokens are issued only to the applicant proving the opaque token. They
        are never returned to the approving member or persisted in this table.
        """
        registration = await self._applicant_registration(
            registration_id, installation_id, activation_token, lock=True,
        )
        now = datetime.now(UTC)
        await self._expire_if_needed(registration, now)
        if registration.status != "approved" or registration.member_id is None:
            raise ForbiddenError("registration is not approved")
        if registration.expires_at <= now:
            raise ForbiddenError("registration authorization is expired")
        member = await self.session.get(Member, registration.member_id, with_for_update=True)
        if member is None or member.deleted_at is not None:
            raise ForbiddenError("registration is unavailable")
        # Only a short, installation-bound replay window is available after a
        # committed activation. This preserves safe response-loss recovery
        # without turning the registration capability into a TTL-long session
        # minting token.
        if registration.activated_at is not None:
            if registration.activation_replay_until is None or registration.activation_replay_until < now:
                raise ForbiddenError("registration activation has already been consumed")
        tokens = await AuthService(self.session, self.settings).issue_session(
            member, installation_id, revoke_current_device_sessions=True, device_name=device_name,
        )
        if registration.activated_at is None:
            registration.activated_at = now
            registration.activation_replay_until = now + self._ACTIVATION_REPLAY_WINDOW
        await self.session.flush()
        return registration, tokens

    async def _applicant_registration(
        self, registration_id: UUID, installation_id: str, activation_token: str, *, lock: bool,
    ) -> PendingRegistration:
        self._validate_installation_id(installation_id)
        if not 32 <= len(activation_token) <= 512:
            raise ForbiddenError("registration authorization is invalid")
        registration = await self.repository.applicant_registration(
            registration_id, installation_id, token_hash(activation_token), lock=lock,
        )
        if registration is None:
            # Never reveal whether an ID exists for a different installation.
            raise ForbiddenError("registration authorization is invalid")
        return registration

    async def _expire_if_needed(self, registration: PendingRegistration, now: datetime) -> None:
        if registration.status == "pending" and registration.expires_at <= now:
            registration.status = "rejected"
            registration.decided_at = now

    @staticmethod
    def _normalize_display_name(value: str) -> tuple[str, str]:
        display = re.sub(r"\s+", " ", unicodedata.normalize("NFKC", value).strip())
        if not 1 <= len(display) <= 80:
            raise ValidationError("display name is invalid")
        if any(unicodedata.category(character).startswith("C") for character in display):
            raise ValidationError("display name is invalid")
        normalized = display.casefold()
        if not normalized:
            raise ValidationError("display name is invalid")
        return display, normalized

    @staticmethod
    def _validate_password(value: str) -> None:
        if not 8 <= len(value) <= 256:
            raise ValidationError("password is invalid")

    @staticmethod
    def _validate_installation_id(value: str) -> None:
        if not 8 <= len(value) <= 128:
            raise ValidationError("installation identifier is invalid")
