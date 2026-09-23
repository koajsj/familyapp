"""Safe departure and two-member-approved removal without erasing history."""
from __future__ import annotations

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import Settings
from ..errors import ConflictError, ForbiddenError, NotFoundError
from ..member_identity import is_initial_member_id
from ..models.entities import Member, MemberRemovalRequest
from ..repositories.auth import AuthRepository
from ..repositories.member_removal import MemberRemovalRepository
from ..repositories.recovery import RecoveryRepository
from ..repositories.sync import SyncRepository


class MemberRemovalService:
    """Identity control-plane mutations. Business rows are never deleted here."""
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.repository = MemberRemovalRepository(session)
        self.auth = AuthRepository(session)
        self.recovery = RecoveryRepository(session)
        self.sync = SyncRepository(session)

    async def leave(self, member_id: UUID) -> int:
        """A dynamic member may leave after the client-side confirmation step."""
        member = await self._removable_active_member(member_id, lock=True)
        return await self._deactivate(member, datetime.now(UTC))

    async def request_removal(self, requester_id: UUID, target_member_id: UUID) -> MemberRemovalRequest:
        if requester_id == target_member_id:
            raise ForbiddenError("use the departure endpoint for your own account")
        target = await self._removable_active_member(target_member_id, lock=True)
        if await self.repository.pending_for_target(target.id):
            raise ConflictError("member_removal_already_pending")
        request = MemberRemovalRequest(target_member_id=target.id, requester_id=requester_id, status="pending")
        try:
            async with self.session.begin_nested():
                self.session.add(request)
                await self.session.flush()
        except IntegrityError as caught_error:
            raise ConflictError("member_removal_already_pending") from caught_error
        return request

    async def reviewable(self) -> list[MemberRemovalRequest]:
        return await self.repository.reviewable()

    async def decide(self, request_id: UUID, approver_id: UUID, decision: str) -> tuple[MemberRemovalRequest, int | None]:
        if decision not in {"approved", "rejected"}:
            raise ConflictError("member_removal_decision_invalid")
        request = await self.repository.request(request_id, lock=True)
        if request is None:
            raise NotFoundError("member removal request not found")
        if request.status != "pending":
            if request.status == decision:
                return request, None
            raise ConflictError("member_removal_already_decided")
        # A removal of another member requires a truly independent active
        # principal. The target's voluntary leave is a separate endpoint.
        if approver_id in {request.requester_id, request.target_member_id}:
            raise ForbiddenError("independent member approval required")
        if await self.repository.active_member(approver_id, lock=True) is None:
            raise ForbiddenError("approver is inactive")
        if await self.repository.active_member(request.requester_id, lock=True) is None:
            raise ConflictError("member_removal_requester_is_not_active")
        target = await self._removable_active_member(request.target_member_id, lock=True)
        now = datetime.now(UTC)
        if decision == "rejected":
            request.status = "rejected"
            request.approver_id = approver_id
            request.decided_at = now
            await self.session.flush()
            return request, None
        # All checks above occur before changing the Member row, devices,
        # sessions, recovery state, request status, or SyncChange.
        request.status = "approved"
        request.approver_id = approver_id
        request.decided_at = now
        # Persist the decision before the bulk stale-request closeout below;
        # otherwise an autoflush-disabled session could still match this row
        # as pending and cancel its own approved audit record.
        await self.session.flush()
        cursor = await self._deactivate(target, now)
        await self.session.flush()
        return request, cursor

    async def _removable_active_member(self, member_id: UUID, *, lock: bool) -> Member:
        if is_initial_member_id(member_id):
            raise ForbiddenError("initial members cannot leave or be removed")
        member = await self.repository.active_member(member_id, lock=lock)
        if member is None:
            raise ConflictError("member_is_not_active")
        # The UUID guard is authoritative. Keep this second consistency check
        # fail-closed if a bad/manual row claims initial protection.
        if member.is_initial_member:
            raise ForbiddenError("initial members cannot leave or be removed")
        return member

    async def _deactivate(self, member: Member, now: datetime) -> int:
        # The approved request is already non-pending; this only closes other
        # requests that could otherwise outlive either party's membership.
        await self.repository.cancel_pending_for_member(member.id, now)
        member.deleted_at = now
        member.version += 1
        await self.session.flush()
        await self.auth.revoke_member_devices(member.id, now)
        await self.auth.revoke_member_refresh_sessions(member.id, now)
        await self.recovery.invalidate_sessions(member.id, now)
        await self.recovery.invalidate_credential(member.id, now)
        await self.session.flush()
        change = await self.sync.append_change("member", member.id, "delete", member.version, None)
        return change.seq
