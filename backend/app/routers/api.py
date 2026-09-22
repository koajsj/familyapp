"""Thin HTTP/WebSocket transport for the future remote-sync backend."""
from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated, Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request, WebSocket, WebSocketDisconnect, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..config import Settings
from ..member_identity import MEMBER_STATUS_IDS
from ..models.entities import Device, MemberStatus
from ..repositories.auth import AuthRepository
from ..schemas.contracts import AuthLoginIn, BootstrapOut, ImportBatchRollbackIn, ImportBatchRollbackOut, MediaCreateIn, MediaDownloadOut, MediaFinalizeIn, MediaUploadOut, MemberStatusIn, PullOut, PushIn, PushOut, RecoveryCredentialIn, RecoveryCredentialOut, RecoveryCredentialStatusOut, RecoveryDeviceSessionIn, RecoveryPasswordResetIn, RecoverySessionOut, RecoveryStartIn, RecoveryTakeoverIn, RefreshIn, TokenPairOut
from ..security import decode_access_token
from ..services.auth_service import AuthService
from ..services.recovery_service import RecoveryAttemptDenied, RecoveryService
from ..services.media_service import MediaService
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
    def __init__(self, member_id: UUID, device_id: UUID) -> None:
        self.member_id = member_id
        self.device_id = device_id


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
    principal = Principal(UUID(payload["sub"]), UUID(payload["device"]))
    device = await session.get(Device, principal.device_id)
    if device is None or device.member_id != principal.member_id or device.revoked_at is not None:
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


@auth_router.post("/login", response_model=TokenPairOut)
async def login(payload: AuthLoginIn, request: Request, session: Session) -> TokenPairOut:
    require_remote_sync_enabled(request)
    access, refresh, device_id = await AuthService(session, settings_for(request)).login(payload.member_key, payload.password, payload.installation_id)
    return TokenPairOut(access_token=access, refresh_token=refresh, expires_in=settings_for(request).access_token_ttl_seconds, device_id=device_id)


@auth_router.post("/refresh", response_model=TokenPairOut)
async def refresh(payload: RefreshIn, request: Request, session: Session) -> TokenPairOut:
    require_remote_sync_enabled(request)
    access, replacement, device_id = await AuthService(session, settings_for(request)).rotate(payload.refresh_token)
    return TokenPairOut(access_token=access, refresh_token=replacement, expires_in=settings_for(request).access_token_ttl_seconds, device_id=device_id)


@auth_router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(payload: RefreshIn, request: Request, session: Session) -> None:
    require_remote_sync_enabled(request)
    await AuthService(session, settings_for(request)).revoke(payload.refresh_token)


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
            payload.member_key, payload.recovery_secret, payload.purpose
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
        recovery_session_id, payload.recovery_token, payload.installation_id
    )
    return TokenPairOut(access_token=access, refresh_token=refresh, expires_in=settings_for(request).access_token_ttl_seconds, device_id=device_id)


@recovery_router.post("/sessions/{recovery_session_id}/takeover", response_model=TokenPairOut)
async def account_takeover(
    recovery_session_id: UUID, payload: RecoveryTakeoverIn, request: Request, session: Session,
) -> TokenPairOut:
    require_remote_sync_enabled(request)
    access, refresh, device_id, _ = await RecoveryService(session, settings_for(request)).complete_takeover(
        recovery_session_id, payload.recovery_token, payload.new_password, payload.installation_id,
        payload.recovery_secret,
    )
    return TokenPairOut(access_token=access, refresh_token=refresh, expires_in=settings_for(request).access_token_ttl_seconds, device_id=device_id)


@member_router.put("/me/status")
async def save_my_status(payload: MemberStatusIn, principal: PrincipalDependency, request: Request, session: Session) -> dict[str, Any]:
    existing = await session.scalar(select(MemberStatus).where(MemberStatus.member_id == principal.member_id))
    if existing is None:
        status_id = MEMBER_STATUS_IDS.get(principal.member_id)
        if status_id is None:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="unknown fixed member")
        existing = MemberStatus(id=status_id, member_id=principal.member_id, status_raw=payload.status, estimated_arrival=payload.estimated_arrival)
        session.add(existing)
    else:
        existing.status_raw = payload.status
        existing.estimated_arrival = payload.estimated_arrival
        existing.version += 1
    await session.flush()
    sync = SyncService(session, settings_for(request))
    change = await sync.repository.append_change("memberStatus", existing.id, "update", existing.version, sync._serialize(existing))
    return {"id": str(existing.id), "version": existing.version, "cursor": change.seq}


@member_router.delete("/devices/{device_id}", status_code=status.HTTP_204_NO_CONTENT)
async def revoke_device(device_id: UUID, principal: PrincipalDependency, session: Session) -> None:
    device = await session.scalar(select(Device).where(Device.id == device_id).with_for_update())
    if device is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="device not found")
    if device.member_id != principal.member_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="device ownership required")
    now = datetime.now(UTC)
    device.revoked_at = now
    await AuthRepository(session).revoke_device_refresh_sessions(device.id, now)


@sync_router.post("/push", response_model=PushOut)
async def push(payload: PushIn, principal: PrincipalDependency, request: Request, session: Session) -> PushOut:
    if payload.device_id != principal.device_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="mutation device mismatch")
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


@media_router.post("", response_model=MediaUploadOut)
async def begin_media(payload: MediaCreateIn, principal: PrincipalDependency, request: Request, session: Session) -> MediaUploadOut:
    asset, grant = await MediaService(
        session, settings_for(request), request.app.state.media_storage
    ).begin_upload(principal.member_id, payload.media_id, payload.mime_type, payload.size_bytes, payload.checksum)
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
    return MediaUploadOut(media_id=asset.id, object_key=asset.object_key, status=asset.status)


@media_router.get("/{media_id}/download", response_model=MediaDownloadOut)
async def download_media(media_id: UUID, principal: PrincipalDependency, request: Request, session: Session) -> MediaDownloadOut:
    download_url = await MediaService(
        session, settings_for(request), request.app.state.media_storage
    ).create_download_url(principal.member_id, media_id)
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
            if device is None or device.member_id != member_id or device.revoked_at is not None:
                await socket.close(code=status.WS_1008_POLICY_VIOLATION)
                return
            device.last_seen_at = datetime.now(UTC)
            await session.commit()
    except Exception:
        await socket.close(code=status.WS_1011_INTERNAL_ERROR)
        return

    hub: CursorNotificationHub = socket.app.state.cursor_hub
    await hub.connect(member_id, socket)
    try:
        while True:
            await socket.receive()  # frames are ignored; REST pull is reliable sync.
    except WebSocketDisconnect:
        hub.disconnect(member_id, socket)


for group in (auth_router, recovery_router, member_router, sync_router, media_router, entity_router):
    router.include_router(group)
