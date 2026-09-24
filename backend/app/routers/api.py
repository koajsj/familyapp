"""Thin HTTP/WebSocket transport for the future remote-sync backend."""
from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated, Any
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Request, WebSocket, WebSocketDisconnect, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..config import Settings
from ..errors import NotFoundError
from ..member_identity import member_status_id
from ..models.entities import Device, Member, MemberStatus, RefreshSession
from ..repositories.sync import SyncRepository
from ..schemas.contracts import ApplicantRegistrationOut, AuthLoginIn, BootstrapOut, CurrentMemberIdentityOut, DeviceOut, ImportBatchRollbackIn, ImportBatchRollbackOut, LoginTokenPairOut, MediaCreateIn, MediaDownloadOut, MediaFinalizeIn, MediaUploadOut, MemberDepartureIn, MemberRemovalDecisionIn, MemberRemovalRequestIn, MemberRemovalRequestOut, MemberStatusIn, MutationAck, PendingRegistrationOut, PermanentDeleteIn, PullOut, PushIn, PushOut, RecoveryCredentialIn, RecoveryCredentialOut, RecoveryCredentialStatusOut, RecoveryDeviceSessionIn, RecoveryPasswordResetIn, RecoverySessionOut, RecoveryStartIn, RecoveryTakeoverIn, RefreshIn, RegistrationAccessIn, RegistrationActivationOut, RegistrationCreateIn, RegistrationCreatedOut, RegistrationDecisionIn, TokenPairOut, TrashMutationIn
from ..security import decode_access_token
from ..services.auth_service import AuthService
from ..services.recovery_service import RecoveryAttemptDenied, RecoveryService
from ..services.media_service import MediaService
from ..services.member_removal_service import MemberRemovalService
from ..services.registration_service import RegistrationService
from ..services.sync_service import ALL_TYPES, SyncService
from ..services.websocket_service import CursorNotificationHub

router = APIRouter(prefix="/v1")
auth_router = APIRouter(prefix="/auth", tags=["auth"])
recovery_router = APIRouter(prefix="/recovery", tags=["recovery"])
member_router = APIRouter(prefix="/members", tags=["members"])
sync_router = APIRouter(prefix="/sync", tags=["sync"])
media_router = APIRouter(prefix="/media", tags=["media"])
entity_router = APIRouter(prefix="/entities", tags=["entities"])
security = HTTPBearer(auto_error=False)


class Principal:
    def __init__(self, member_id: UUID, device_id: UUID, session_id: UUID) -> None:
        self.member_id = member_id
        self.device_id = device_id
        self.session_id = session_id


def settings_for(request: Request) -> Settings:
    return request.app.state.settings


def require_remote_sync_enabled(request: Request) -> None:
    if not settings_for(request).remote_sync_enabled:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="remote sync is disabled")


async def session_for(request: Request):
    factory: async_sessionmaker[AsyncSession] = request.app.state.session_factory
    async with factory() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise


Session = Annotated[AsyncSession, Depends(session_for)]


async def current_principal(request: Request, session: Session, credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(security)]) -> Principal:
    require_remote_sync_enabled(request)
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="missing bearer token")
    payload = decode_access_token(credentials.credentials, settings_for(request).access_token_secret)
    if payload is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid access token")
    principal = Principal(UUID(payload["sub"]), UUID(payload["device"]), UUID(payload["session"]))
    refresh_session = await session.get(RefreshSession, principal.session_id)
    device = await session.get(Device, principal.device_id)
    member = await session.get(Member, principal.member_id)
    if (
        refresh_session is None or refresh_session.member_id != principal.member_id
        or refresh_session.device_id != principal.device_id or refresh_session.revoked_at is not None
        or refresh_session.expires_at <= datetime.now(UTC)
        or
        device is None or device.member_id != principal.member_id or device.revoked_at is not None
        or member is None or member.deleted_at is not None
    ):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="device session is unavailable")
    device.last_seen_at = datetime.now(UTC)
    return principal


PrincipalDependency = Annotated[Principal, Depends(current_principal)]


@router.get("/health", include_in_schema=False)
async def health(request: Request) -> dict[str, str]:
    return {"status": "ok", "mode": "future-remote-service", "timezone": settings_for(request).family_timezone}


@router.get("/ready", include_in_schema=False)
async def readiness(session: Session) -> dict[str, str]:
    await session.execute(select(1))
    return {"status": "ready"}


@auth_router.post("/login", response_model=LoginTokenPairOut)
async def login(payload: AuthLoginIn, request: Request, session: Session) -> LoginTokenPairOut:
    require_remote_sync_enabled(request)
    access, refresh, device_id, member_id = await AuthService(session, settings_for(request)).login(
        payload.member_key, payload.password, payload.installation_id, payload.device_name,
    )
    return LoginTokenPairOut(access_token=access, refresh_token=refresh, expires_in=settings_for(request).access_token_ttl_seconds, device_id=device_id, member_id=member_id)


def registration_outcome(value) -> PendingRegistrationOut:
    return PendingRegistrationOut(
        id=value.id, display_name=value.display_name, status=value.status,
        created_at=value.created_at, expires_at=value.expires_at,
        member_id=value.member_id, approved_by=value.approved_by,
        rejected_by=value.rejected_by, decided_at=value.decided_at,
    )


def applicant_registration_outcome(value) -> ApplicantRegistrationOut:
    # A pending applicant can inspect only its own application state. Approval
    # actor/member identifiers remain visible exclusively to authenticated reviewers.
    return ApplicantRegistrationOut(
        id=value.id, display_name=value.display_name, status=value.status,
        created_at=value.created_at, expires_at=value.expires_at, decided_at=value.decided_at,
    )


def member_removal_outcome(value) -> MemberRemovalRequestOut:
    return MemberRemovalRequestOut(
        id=value.id, target_member_id=value.target_member_id,
        requester_id=value.requester_id, approver_id=value.approver_id,
        status=value.status, created_at=value.created_at, decided_at=value.decided_at,
    )


def device_outcome(value: Device, current_device_id: UUID) -> DeviceOut:
    return DeviceOut(
        id=value.id,
        display_name=value.display_name,
        first_seen_at=value.created_at,
        last_seen_at=value.last_seen_at,
        revoked_at=value.revoked_at,
        is_current=value.id == current_device_id,
        is_location_source=value.is_location_source,
    )


@auth_router.post("/registrations", response_model=RegistrationCreatedOut, status_code=status.HTTP_201_CREATED)
async def submit_registration(payload: RegistrationCreateIn, request: Request, session: Session) -> RegistrationCreatedOut:
    require_remote_sync_enabled(request)
    registration, activation_token = await RegistrationService(session, settings_for(request)).submit(
        display_name=payload.display_name, password=payload.password,
        invite_code=payload.invite_code, installation_id=payload.installation_id,
    )
    result = applicant_registration_outcome(registration)
    return RegistrationCreatedOut(**result.model_dump(), activation_token=activation_token)


@auth_router.get("/registrations/{registration_id}", response_model=ApplicantRegistrationOut)
async def registration_status(
    registration_id: UUID, request: Request, session: Session,
    installation_id: Annotated[str, Header(alias="X-FamilyApp-Installation-ID")],
    activation_token: Annotated[str, Header(alias="X-FamilyApp-Registration-Token")],
) -> ApplicantRegistrationOut:
    # The applicant capability stays in a dedicated header; it is never
    # promoted to an Authorization bearer credential or accepted by business APIs.
    require_remote_sync_enabled(request)
    registration = await RegistrationService(session, settings_for(request)).applicant_status(
        registration_id, installation_id, activation_token,
    )
    return applicant_registration_outcome(registration)


@auth_router.delete("/registrations/{registration_id}", response_model=ApplicantRegistrationOut)
async def cancel_registration(
    registration_id: UUID, payload: RegistrationAccessIn, request: Request, session: Session,
) -> ApplicantRegistrationOut:
    require_remote_sync_enabled(request)
    registration = await RegistrationService(session, settings_for(request)).cancel(
        registration_id, payload.installation_id, payload.activation_token,
    )
    return applicant_registration_outcome(registration)


@auth_router.post("/registrations/{registration_id}/activate", response_model=RegistrationActivationOut)
async def activate_registration(
    registration_id: UUID, payload: RegistrationAccessIn, request: Request, session: Session,
) -> RegistrationActivationOut:
    require_remote_sync_enabled(request)
    registration, (access, refresh, device_id) = await RegistrationService(session, settings_for(request)).activate(
        registration_id, payload.installation_id, payload.activation_token, payload.device_name,
    )
    assert registration.member_id is not None
    # A response-loss replay replaces the installation's previous refresh
    # session. Its old socket must not outlive that revocation.
    await session.commit()
    await request.app.state.cursor_hub.disconnect_device(registration.member_id, device_id)
    return RegistrationActivationOut(
        access_token=access, refresh_token=refresh,
        expires_in=settings_for(request).access_token_ttl_seconds,
        device_id=device_id, member_id=registration.member_id,
    )


@auth_router.post("/refresh", response_model=TokenPairOut)
async def refresh(payload: RefreshIn, request: Request, session: Session) -> TokenPairOut:
    require_remote_sync_enabled(request)
    access, replacement, device_id, member_id = await AuthService(session, settings_for(request)).rotate(payload.refresh_token)
    await session.commit()
    # The old access token was bound to the now-revoked refresh session.
    # Existing sockets must reconnect with the newly issued access token.
    await request.app.state.cursor_hub.disconnect_device(member_id, device_id)
    return TokenPairOut(access_token=access, refresh_token=replacement, expires_in=settings_for(request).access_token_ttl_seconds, device_id=device_id)


@auth_router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(payload: RefreshIn, request: Request, session: Session) -> None:
    require_remote_sync_enabled(request)
    revoked = await AuthService(session, settings_for(request)).revoke(payload.refresh_token)
    await session.commit()
    if revoked is not None:
        await request.app.state.cursor_hub.disconnect_device(*revoked)


@recovery_router.put("/credential", response_model=RecoveryCredentialOut)
async def register_recovery_credential(
    payload: RecoveryCredentialIn, principal: PrincipalDependency, request: Request, session: Session,
) -> RecoveryCredentialOut:
    generation = await RecoveryService(session, settings_for(request)).register_credential(
        principal.member_id, payload.recovery_secret
    )
    return RecoveryCredentialOut(generation=generation)


@recovery_router.get("/credential", response_model=RecoveryCredentialStatusOut)
async def recovery_credential_status(
    principal: PrincipalDependency, request: Request, session: Session,
) -> RecoveryCredentialStatusOut:
    generation = await RecoveryService(session, settings_for(request)).credential_status(principal.member_id)
    return RecoveryCredentialStatusOut(configured=generation is not None, generation=generation)


@recovery_router.post("/sessions", response_model=RecoverySessionOut)
async def begin_recovery(payload: RecoveryStartIn, request: Request, session: Session) -> RecoverySessionOut:
    require_remote_sync_enabled(request)
    try:
        authorization, token = await RecoveryService(session, settings_for(request)).begin(
            payload.member_id, payload.recovery_secret, payload.purpose
        )
    except RecoveryAttemptDenied as error:
        # Persist the failed-attempt backoff before returning the generic
        # denial. The dependency's later rollback is then a no-op.
        await session.commit()
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="recovery is unavailable") from error
    return RecoverySessionOut(
        recovery_session_id=authorization.id,
        recovery_token=token,
        purpose=authorization.purpose,
        expires_at=authorization.expires_at,
        recovery_generation=authorization.recovery_generation,
    )


@recovery_router.post("/sessions/{recovery_session_id}/password", status_code=status.HTTP_204_NO_CONTENT)
async def reset_password(
    recovery_session_id: UUID, payload: RecoveryPasswordResetIn, request: Request, session: Session,
) -> None:
    require_remote_sync_enabled(request)
    await RecoveryService(session, settings_for(request)).reset_password(
        recovery_session_id, payload.recovery_token, payload.new_password
    )


@recovery_router.post("/sessions/{recovery_session_id}/device", response_model=TokenPairOut)
async def recover_new_device(
    recovery_session_id: UUID, payload: RecoveryDeviceSessionIn, request: Request, session: Session,
) -> TokenPairOut:
    require_remote_sync_enabled(request)
    access, refresh, device_id = await RecoveryService(session, settings_for(request)).issue_new_device_session(
        recovery_session_id, payload.recovery_token, payload.installation_id, payload.device_name,
    )
    return TokenPairOut(access_token=access, refresh_token=refresh, expires_in=settings_for(request).access_token_ttl_seconds, device_id=device_id)


@recovery_router.post("/sessions/{recovery_session_id}/takeover", response_model=TokenPairOut)
async def account_takeover(
    recovery_session_id: UUID, payload: RecoveryTakeoverIn, request: Request, session: Session,
) -> TokenPairOut:
    require_remote_sync_enabled(request)
    access, refresh, device_id, _ = await RecoveryService(session, settings_for(request)).complete_takeover(
        recovery_session_id, payload.recovery_token, payload.new_password, payload.installation_id,
        payload.recovery_secret, payload.device_name,
    )
    decoded = decode_access_token(access, settings_for(request).access_token_secret)
    if decoded is None or not isinstance(decoded.get("sub"), str):
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="invalid takeover session")
    await session.commit()
    # Takeover replaces the current installation's old refresh session too.
    # Close its old socket as well; the new session reconnects independently.
    await request.app.state.cursor_hub.disconnect_member(UUID(decoded["sub"]))
    return TokenPairOut(access_token=access, refresh_token=refresh, expires_in=settings_for(request).access_token_ttl_seconds, device_id=device_id)


@member_router.put("/me/status")
async def save_my_status(payload: MemberStatusIn, principal: PrincipalDependency, request: Request, session: Session) -> dict[str, Any]:
    existing = await session.scalar(select(MemberStatus).where(MemberStatus.member_id == principal.member_id))
    if existing is None:
        existing = MemberStatus(id=member_status_id(principal.member_id), member_id=principal.member_id, status_raw=payload.status, estimated_arrival=payload.estimated_arrival)
        session.add(existing)
    else:
        existing.status_raw = payload.status
        existing.estimated_arrival = payload.estimated_arrival
        existing.version += 1
    await session.flush()
    sync = SyncService(session, settings_for(request))
    change = await sync.repository.append_change("memberStatus", existing.id, "update", existing.version, sync._serialize(existing))
    await session.commit()
    await request.app.state.cursor_hub.notify_latest_cursor(change.seq)
    return {"id": str(existing.id), "version": existing.version, "cursor": change.seq}


@member_router.post("/me/leave", status_code=status.HTTP_204_NO_CONTENT)
async def leave_family(
    payload: MemberDepartureIn, principal: PrincipalDependency, request: Request, session: Session,
) -> None:
    # ``payload.confirmed`` is intentionally read to make the confirmation a
    # required wire-level contract, rather than a UI-only convention.
    assert payload.confirmed is True
    cursor = await MemberRemovalService(session, settings_for(request)).leave(principal.member_id)
    await session.commit()
    await request.app.state.cursor_hub.disconnect_member(principal.member_id)
    await request.app.state.cursor_hub.notify_latest_cursor(cursor)


@member_router.post("/removal-requests", response_model=MemberRemovalRequestOut, status_code=status.HTTP_201_CREATED)
async def request_member_removal(
    payload: MemberRemovalRequestIn, principal: PrincipalDependency, request: Request, session: Session,
) -> MemberRemovalRequestOut:
    value = await MemberRemovalService(session, settings_for(request)).request_removal(
        principal.member_id, payload.target_member_id,
    )
    return member_removal_outcome(value)


@member_router.get("/removal-requests", response_model=list[MemberRemovalRequestOut])
async def list_member_removal_requests(
    principal: PrincipalDependency, request: Request, session: Session,
) -> list[MemberRemovalRequestOut]:
    del principal
    return [member_removal_outcome(value) for value in await MemberRemovalService(session, settings_for(request)).reviewable()]


@member_router.post("/removal-requests/{removal_request_id}/decision", response_model=MemberRemovalRequestOut)
async def decide_member_removal(
    removal_request_id: UUID, payload: MemberRemovalDecisionIn, principal: PrincipalDependency,
    request: Request, session: Session,
) -> MemberRemovalRequestOut:
    value, cursor = await MemberRemovalService(session, settings_for(request)).decide(
        removal_request_id, principal.member_id, payload.decision,
    )
    if cursor is not None:
        await session.commit()
        if value.status == "approved":
            await request.app.state.cursor_hub.disconnect_member(value.target_member_id)
        await request.app.state.cursor_hub.notify_latest_cursor(cursor)
    return member_removal_outcome(value)


@member_router.get("/join-requests", response_model=list[PendingRegistrationOut])
async def list_join_requests(principal: PrincipalDependency, request: Request, session: Session) -> list[PendingRegistrationOut]:
    # Any authenticated, active household member may review applications.
    del principal
    return [registration_outcome(value) for value in await RegistrationService(session, settings_for(request)).reviewable()]


@member_router.post("/join-requests/{registration_id}/decision", response_model=PendingRegistrationOut)
async def decide_join_request(
    registration_id: UUID, payload: RegistrationDecisionIn, principal: PrincipalDependency,
    request: Request, session: Session,
) -> PendingRegistrationOut:
    registration, cursor = await RegistrationService(session, settings_for(request)).decide(
        registration_id, principal.member_id, payload.decision,
    )
    # Sync delivery is notified only after the member-creation transaction is
    # durable. Rejected/idempotent decisions do not manufacture a SyncChange.
    if cursor is not None:
        await session.commit()
        await request.app.state.cursor_hub.notify_latest_cursor(cursor)
    return registration_outcome(registration)


@member_router.get("/me/identity", response_model=CurrentMemberIdentityOut)
async def current_member_identity(principal: PrincipalDependency) -> CurrentMemberIdentityOut:
    return CurrentMemberIdentityOut(member_id=principal.member_id)


@member_router.get("/me/devices", response_model=list[DeviceOut])
async def list_my_devices(principal: PrincipalDependency, request: Request, session: Session) -> list[DeviceOut]:
    values = await AuthService(session, settings_for(request)).devices(principal.member_id)
    return [device_outcome(value, principal.device_id) for value in values]


@member_router.post("/me/devices/revoke-others", status_code=status.HTTP_204_NO_CONTENT)
async def revoke_other_devices(principal: PrincipalDependency, request: Request, session: Session) -> None:
    revoked_device_ids = await AuthService(session, settings_for(request)).revoke_other_devices(
        principal.member_id, principal.device_id,
    )
    await session.commit()
    for device_id in revoked_device_ids:
        await request.app.state.cursor_hub.disconnect_device(principal.member_id, device_id)


@member_router.post("/me/devices/current/location-source", status_code=status.HTTP_204_NO_CONTENT)
async def select_current_location_source(
    principal: PrincipalDependency, request: Request, session: Session,
) -> None:
    await AuthService(session, settings_for(request)).select_location_source(
        principal.member_id, principal.device_id,
    )


@member_router.delete("/me/devices/{device_id}", status_code=status.HTTP_204_NO_CONTENT)
@member_router.delete("/devices/{device_id}", status_code=status.HTTP_204_NO_CONTENT, include_in_schema=False)
async def revoke_device(device_id: UUID, principal: PrincipalDependency, request: Request, session: Session) -> None:
    # Keep the older path as a transport alias while routing both through the
    # same ownership and refresh-session revocation boundary.
    await AuthService(session, settings_for(request)).revoke_device(principal.member_id, device_id)
    await session.commit()
    await request.app.state.cursor_hub.disconnect_device(principal.member_id, device_id)


@sync_router.post("/push", response_model=PushOut)
async def push(payload: PushIn, principal: PrincipalDependency, request: Request, session: Session) -> PushOut:
    if payload.device_id != principal.device_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="mutation device mismatch")
    # The dependency validates at request entry. Hold these identity locks
    # through the business commit so a concurrent removal/revoke/logout cannot
    # win after that check but before a mutation is written. Keep the same
    # Member -> Device -> RefreshSession order as the Auth control plane.
    member = await session.scalar(select(Member).where(Member.id == principal.member_id)
                                  .with_for_update().execution_options(populate_existing=True))
    device = await session.scalar(select(Device).where(Device.id == principal.device_id)
                                  .with_for_update().execution_options(populate_existing=True))
    refresh_session = await session.scalar(select(RefreshSession).where(RefreshSession.id == principal.session_id)
                                          .with_for_update().execution_options(populate_existing=True))
    if (member is None or member.deleted_at is not None or device is None
        or device.member_id != principal.member_id or device.revoked_at is not None
        or refresh_session is None or refresh_session.member_id != principal.member_id
        or refresh_session.device_id != principal.device_id
        or refresh_session.revoked_at is not None or refresh_session.expires_at <= datetime.now(UTC)):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="device session is unavailable")
    sync = SyncService(session, settings_for(request))
    applied, conflicts, latest = await sync.push(principal.member_id, principal.device_id, payload.mutations)
    await session.commit()
    await request.app.state.cursor_hub.notify_latest_cursor(latest)
    return PushOut(applied=applied, conflicts=conflicts, latest_cursor=latest)


@sync_router.get("/pull", response_model=PullOut)
async def pull(request: Request, session: Session, principal: PrincipalDependency, after: int = 0, limit: int = 100) -> PullOut:
    if not 1 <= limit <= 500:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="limit must be 1...500")
    try:
        changes, latest, has_more = await SyncService(session, settings_for(request)).pull(after, limit, principal.device_id)
    except Exception as error:
        code = getattr(error, "args", [None])[0]
        if code == "sync_cursor_expired":
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail={"code": code, "message": "bootstrap is required"}) from error
        if code == "invalid_sync_cursor":
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail={"code": code, "message": "cursor is ahead of the server; bootstrap is required"}) from error
        raise
    return PullOut(changes=changes, latest_cursor=latest, has_more=has_more)


@sync_router.post("/import-batches/{batch_id}/rollback", response_model=ImportBatchRollbackOut)
async def rollback_import_batch(batch_id: UUID, payload: ImportBatchRollbackIn, principal: PrincipalDependency, request: Request, session: Session) -> ImportBatchRollbackOut:
    result = await SyncService(session, settings_for(request)).rollback_import_batch(
        principal.member_id, principal.device_id, batch_id, payload.mutation_id, payload.expected_version
    )
    # Notify only after the enclosing request transaction is durable, matching
    # the normal mutation-push path.
    await session.commit()
    await request.app.state.cursor_hub.notify_latest_cursor(result.latest_cursor)
    return result


@sync_router.get("/bootstrap", response_model=BootstrapOut)
async def bootstrap(principal: PrincipalDependency, request: Request) -> BootstrapOut:
    # Authentication ran in its own request session. Start a fresh transaction
    # here so isolation is selected before the first snapshot query.
    factory: async_sessionmaker[AsyncSession] = request.app.state.session_factory
    async with factory() as snapshot_session:
        async with snapshot_session.begin():
            await snapshot_session.execute(text("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY"))
            entities, latest = await SyncService(snapshot_session, settings_for(request)).bootstrap()
    return BootstrapOut(entities=entities, latest_cursor=latest, family_timezone=settings_for(request).family_timezone)


@sync_router.get("/trash/{entity_type}")
async def list_trash(
    entity_type: str, principal: PrincipalDependency, request: Request, session: Session,
    after_id: UUID | None = None, limit: int = 100,
) -> dict[str, Any]:
    if not 1 <= limit <= 500:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="limit must be 1...500")
    items = await SyncService(session, settings_for(request)).deleted_items(
        principal.member_id, entity_type, after_id=after_id, limit=limit
    )
    return {"items": items, "next_id": items[-1]["id"] if len(items) == limit else None}


@sync_router.post("/trash/{entity_type}/{entity_id}/restore", response_model=MutationAck)
async def restore_deleted_item(
    entity_type: str, entity_id: UUID, payload: TrashMutationIn,
    principal: PrincipalDependency, request: Request, session: Session,
) -> MutationAck:
    result = await SyncService(session, settings_for(request)).change_deleted_item(
        principal.member_id, principal.device_id, entity_type, entity_id,
        payload.mutation_id, payload.expected_version, permanent=False,
    )
    await session.commit()
    await request.app.state.cursor_hub.notify_latest_cursor(result.seq)
    return result


@sync_router.post("/trash/{entity_type}/{entity_id}/permanent-delete", response_model=MutationAck)
async def permanently_delete_item(
    entity_type: str, entity_id: UUID, payload: PermanentDeleteIn,
    principal: PrincipalDependency, request: Request, session: Session,
) -> MutationAck:
    result = await SyncService(session, settings_for(request)).change_deleted_item(
        principal.member_id, principal.device_id, entity_type, entity_id,
        payload.mutation_id, payload.expected_version, permanent=True,
    )
    await session.commit()
    await request.app.state.cursor_hub.notify_latest_cursor(result.seq)
    return result


@media_router.post("", response_model=MediaUploadOut)
async def begin_media(payload: MediaCreateIn, principal: PrincipalDependency, request: Request, session: Session) -> MediaUploadOut:
    asset, grant = await MediaService(
        session, settings_for(request), request.app.state.media_storage
    ).begin_upload(principal.member_id, payload.media_id, payload.mime_type, payload.size_bytes, payload.checksum, payload.file_name)
    # The client may immediately PUT and finalize after receiving this grant.
    # Make the stable MediaAsset identity durable before sending it.
    await session.commit()
    await request.app.state.cursor_hub.notify_latest_cursor(await SyncRepository(session).latest_cursor())
    return MediaUploadOut(
        media_id=asset.id,
        object_key=asset.object_key,
        upload_url=grant.url if grant else None,
        upload_headers=grant.headers if grant else {},
        status=asset.status,
    )


@media_router.post("/{media_id}/finalize", response_model=MediaUploadOut)
async def finalize_media(media_id: UUID, payload: MediaFinalizeIn, principal: PrincipalDependency, request: Request, session: Session) -> MediaUploadOut:
    asset = await MediaService(
        session, settings_for(request), request.app.state.media_storage
    ).finalize(principal.member_id, media_id, payload.checksum)
    await session.commit()
    # A finalized asset is now part of the metadata stream. The client may
    # immediately push its Message.media_id without racing this commit.
    await request.app.state.cursor_hub.notify_latest_cursor(await SyncRepository(session).latest_cursor())
    return MediaUploadOut(media_id=asset.id, object_key=asset.object_key, status=asset.status)


@media_router.get("/{media_id}/download", response_model=MediaDownloadOut)
async def download_media(media_id: UUID, principal: PrincipalDependency, request: Request, session: Session) -> MediaDownloadOut:
    download_url = await MediaService(
        session, settings_for(request), request.app.state.media_storage
    ).create_download_url(principal.member_id, media_id)
    if download_url is None:
        await session.commit()
        await request.app.state.cursor_hub.notify_latest_cursor(await SyncRepository(session).latest_cursor())
        raise NotFoundError("media object is unavailable")
    return MediaDownloadOut(
        media_id=media_id,
        download_url=download_url,
        expires_in=settings_for(request).media_s3_presign_seconds,
    )


@entity_router.get("/{entity_type}")
async def list_entity(entity_type: str, principal: PrincipalDependency, request: Request, session: Session, cursor: str | None = None, limit: int = 100) -> dict[str, Any]:
    if entity_type not in ALL_TYPES or not 1 <= limit <= 500:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="invalid entity type or limit")
    model = ALL_TYPES[entity_type]
    statement = SyncService._active_snapshot_statement(entity_type, model).order_by(model.id).limit(limit + 1)
    if cursor:
        statement = statement.where(model.id > UUID(cursor))
    values = (await session.scalars(statement)).all()
    sync = SyncService(session, settings_for(request))
    return {"items": [sync._serialize(value) for value in values[:limit]], "next_cursor": str(values[limit].id) if len(values) > limit else None}


@router.websocket("/ws")
async def websocket_notifications(socket: WebSocket) -> None:
    settings: Settings = socket.app.state.settings
    if not settings.remote_sync_enabled:
        await socket.close(code=status.WS_1008_POLICY_VIOLATION)
        return
    token = socket.headers.get("authorization", "").removeprefix("Bearer ").strip()
    payload = decode_access_token(token, settings.access_token_secret)
    if payload is None:
        await socket.close(code=status.WS_1008_POLICY_VIOLATION)
        return
    try:
        member_id = UUID(payload["sub"])
        device_id = UUID(payload["device"])
    except (KeyError, TypeError, ValueError):
        await socket.close(code=status.WS_1008_POLICY_VIOLATION)
        return

    # WebSockets bypass FastAPI's HTTP dependency graph, so they must perform
    # the same device-revocation check as ``current_principal`` before being
    # registered with the notification hub.
    factory: async_sessionmaker[AsyncSession] = socket.app.state.session_factory
    try:
        async with factory() as session:
            device = await session.get(Device, device_id)
            member = await session.get(Member, member_id)
            refresh_session = await session.get(RefreshSession, UUID(payload["session"]))
            if (
                refresh_session is None or refresh_session.member_id != member_id
                or refresh_session.device_id != device_id or refresh_session.revoked_at is not None
                or refresh_session.expires_at <= datetime.now(UTC)
                or
                device is None or device.member_id != member_id or device.revoked_at is not None
                or member is None or member.deleted_at is not None
            ):
                await socket.close(code=status.WS_1008_POLICY_VIOLATION)
                return
            device.last_seen_at = datetime.now(UTC)
            await session.commit()
    except Exception:
        await socket.close(code=status.WS_1011_INTERNAL_ERROR)
        return

    hub: CursorNotificationHub = socket.app.state.cursor_hub
    await hub.connect(member_id, device_id, socket)
    # A revoke/rotation may commit after the first DB check but before hub
    # registration. Recheck after registration: any later revoke now reaches
    # this registered socket through disconnect_device/member.
    try:
        async with factory() as session:
            fresh_session = await session.get(RefreshSession, UUID(payload["session"]))
            fresh_device = await session.get(Device, device_id)
            fresh_member = await session.get(Member, member_id)
            if (
                fresh_session is None or fresh_session.member_id != member_id
                or fresh_session.device_id != device_id or fresh_session.revoked_at is not None
                or fresh_session.expires_at <= datetime.now(UTC)
                or fresh_device is None or fresh_device.member_id != member_id
                or fresh_device.revoked_at is not None
                or fresh_member is None or fresh_member.deleted_at is not None
            ):
                hub.disconnect(member_id, device_id, socket)
                await socket.close(code=status.WS_1008_POLICY_VIOLATION)
                return
            sync = SyncRepository(session)
            latest = await sync.latest_cursor()
            earliest = await sync.earliest_cursor()
            acknowledged = fresh_device.last_acked_sync_seq
            # This is only a hint. The client still uses its own durable cursor
            # and the authoritative Pull boundary check before applying data.
            requires_bootstrap = acknowledged > 0 and (
                acknowledged > latest or
                (earliest is None and acknowledged != latest) or
                (earliest is not None and acknowledged < earliest - 1)
            )
            await hub.send_cursor(socket, latest, requires_bootstrap=requires_bootstrap)
    except Exception:
        hub.disconnect(member_id, device_id, socket)
        try:
            await socket.close(code=status.WS_1011_INTERNAL_ERROR)
        except RuntimeError:
            pass
        return
    try:
        while True:
            await socket.receive_text()  # frames are ignored; REST pull is reliable sync.
    except WebSocketDisconnect:
        pass
    finally:
        hub.disconnect(member_id, device_id, socket)


for group in (auth_router, recovery_router, member_router, sync_router, media_router, entity_router):
    router.include_router(group)
