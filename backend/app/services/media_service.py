"""Private object-store boundary for optional, direct-to-object-store media."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
import re
from typing import Protocol
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import Settings
from ..errors import ConflictError, MediaUnavailableError, NotFoundError, ValidationError
from ..models.entities import MediaAsset
from ..repositories.media import MediaRepository
from ..repositories.sync import SyncRepository


CHAT_FILE_MIME_BY_EXTENSION = {
    "pdf": "application/pdf", "doc": "application/msword",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xls": "application/vnd.ms-excel",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "ppt": "application/vnd.ms-powerpoint",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "txt": "text/plain", "zip": "application/zip",
}


@dataclass(frozen=True)
class PresignedUpload:
    url: str
    headers: dict[str, str]


@dataclass(frozen=True)
class StoredObject:
    object_key: str
    last_modified: datetime | None


class MediaStorage(Protocol):
    async def create_upload_grant(
        self, object_key: str, mime_type: str, size_bytes: int, checksum: str
    ) -> PresignedUpload: ...

    async def verify_upload(
        self, object_key: str, mime_type: str, size_bytes: int, checksum: str
    ) -> bool: ...

    async def object_exists(self, object_key: str) -> bool: ...
    async def delete(self, object_key: str) -> None: ...
    async def create_download_url(self, object_key: str) -> str: ...
    async def list_objects(self, prefix: str) -> list[StoredObject]: ...


class UnconfiguredMediaStorage:
    async def create_upload_grant(
        self, object_key: str, mime_type: str, size_bytes: int, checksum: str
    ) -> PresignedUpload:
        raise MediaUnavailableError("media storage is not configured")

    async def verify_upload(
        self, object_key: str, mime_type: str, size_bytes: int, checksum: str
    ) -> bool:
        raise MediaUnavailableError("media storage is not configured")

    async def object_exists(self, object_key: str) -> bool:
        raise MediaUnavailableError("media storage is not configured")

    async def delete(self, object_key: str) -> None:
        raise MediaUnavailableError("media storage is not configured")

    async def create_download_url(self, object_key: str) -> str:
        raise MediaUnavailableError("media storage is not configured")

    async def list_objects(self, prefix: str) -> list[StoredObject]:
        raise MediaUnavailableError("media storage is not configured")


def build_media_storage(settings: Settings) -> MediaStorage:
    """Construct storage only when the optional S3 backend is enabled.

    The S3 SDK stays unimported in the normal ``unconfigured`` mode, so a
    local-only deployment can start its core API without object-store setup.
    """
    if settings.media_backend == "unconfigured":
        return UnconfiguredMediaStorage()
    if settings.media_backend == "s3":
        from .s3_media_storage import S3CompatibleMediaStorage

        return S3CompatibleMediaStorage(settings)
    raise ValueError("unsupported media storage backend")


class MediaService:
    def __init__(self, session: AsyncSession, settings: Settings, storage: MediaStorage | None = None) -> None:
        self.session = session
        self.settings = settings
        self.storage = storage or UnconfiguredMediaStorage()
        self.repository = MediaRepository(session)

    async def begin_upload(
        self, owner_id: UUID, media_id: UUID, mime_type: str, size_bytes: int, checksum: str,
        file_name: str | None = None,
    ) -> tuple[MediaAsset, PresignedUpload | None]:
        mime_type = mime_type.strip().lower()
        safe_name = file_name.replace("\\", "/").split("/")[-1][:255] if file_name else None
        self._validate_upload(mime_type, size_bytes, checksum, safe_name)
        normalized_checksum = checksum.lower()
        existing = await self.repository.get_including_deleted(media_id)
        if existing is not None:
            if existing.deleted_at is not None:
                raise ConflictError("media asset has been permanently removed")
            if existing.owner_id != owner_id:
                raise NotFoundError("media asset is unavailable")
            if (existing.mime_type, existing.size_bytes, existing.checksum, existing.file_name) != (mime_type, size_bytes, normalized_checksum, safe_name):
                raise ConflictError("media upload identity conflict")
            if existing.status == "ready" and existing.finalized_at is not None:
                return existing, None
            if existing.status == "missing":
                raise ConflictError("media object is missing")
            if existing.expires_at is not None and existing.expires_at <= datetime.now(UTC):
                # Reuse the same metadata/object identity after an interrupted
                # pre-finalize attempt. A fresh signed PUT may overwrite an
                # incomplete object, but it never creates a second asset.
                existing.expires_at = datetime.now(UTC) + timedelta(seconds=self.settings.media_upload_expiry_seconds)
            # A previous direct PUT may have succeeded while its finalize
            # response was lost. Verification lets the same media identity
            # advance without uploading identical bytes again.
            if await self.storage.verify_upload(
                existing.object_key, existing.mime_type, existing.size_bytes, existing.checksum
            ):
                return existing, None
            grant = await self.storage.create_upload_grant(
                existing.object_key, existing.mime_type, existing.size_bytes, existing.checksum
            )
            return existing, grant
        object_key = f"{self.settings.media_object_prefix}/{owner_id}/{media_id}"
        asset = MediaAsset(
            id=media_id,
            owner_id=owner_id,
            object_key=object_key,
            mime_type=mime_type,
            size_bytes=size_bytes,
            checksum=normalized_checksum,
            file_name=safe_name,
            status="pending",
            expires_at=datetime.now(UTC) + timedelta(seconds=self.settings.media_upload_expiry_seconds),
        )
        self.session.add(asset)
        await self.session.flush()
        grant = await self.storage.create_upload_grant(
            asset.object_key, asset.mime_type, asset.size_bytes, asset.checksum
        )
        return asset, grant

    async def finalize(self, actor_id: UUID, media_id: UUID, checksum: str) -> MediaAsset:
        asset = await self.repository.get(media_id)
        if asset is None or asset.owner_id != actor_id:
            raise NotFoundError("media asset is unavailable")
        if asset.status == "missing":
            raise ConflictError("media object is missing")
        if asset.status == "ready":
            if asset.checksum != checksum.lower():
                raise ConflictError("media checksum conflict")
            return asset
        if asset.expires_at is not None and asset.expires_at <= datetime.now(UTC):
            raise ValidationError("media upload has expired")
        if asset.checksum != checksum.lower() or not await self.storage.verify_upload(
            asset.object_key, asset.mime_type, asset.size_bytes, asset.checksum
        ):
            raise ValidationError("uploaded media cannot be verified")
        asset.status = "ready"
        asset.finalized_at = datetime.now(UTC)
        asset.expires_at = None
        await self.session.flush()
        # Pending grants are private control-plane state. Only a verified,
        # finalized asset enters the shared metadata stream, atomically with
        # its ready status. A repeated finalize returns above without a second
        # change or a second asset.
        from .sync_service import SyncService
        await SyncRepository(self.session).append_change(
            "mediaAsset", asset.id, "create", asset.version, SyncService._serialize(asset)
        )
        return asset

    async def create_download_url(self, actor_id: UUID, media_id: UUID) -> str | None:
        asset = await self.repository.get(media_id)
        # Pending/missing assets never get a download grant. They remain
        # owner-only through the upload/finalize routes, even when a client
        # knows their UUID.
        if asset is None or asset.status != "ready" or asset.finalized_at is None:
            raise NotFoundError("media asset is unavailable")
        # All supported media types are chat attachments. A finalized but
        # unreferenced upload must not become a download capability merely
        # because its uploader knows the asset ID. Soft-deleted/recalled
        # messages also cease granting access until an authorized restore.
        if not await self.repository.has_active_family_chat_attachment(asset):
            raise NotFoundError("media asset is unavailable")
        if not await self.storage.object_exists(asset.object_key):
            # Two downloads may discover the same missing object together.
            # Lock and refresh before emitting a change so the transition is
            # published once with a strictly advancing version.
            locked = await self.session.scalar(
                select(MediaAsset).where(MediaAsset.id == media_id)
                .with_for_update().execution_options(populate_existing=True)
            )
            if locked is None or locked.deleted_at is not None or locked.status != "ready":
                return None
            locked.status = "missing"
            locked.version += 1
            await self.session.flush()
            # A download can be the first request to discover an object-store
            # loss. Publish the same authoritative metadata transition as the
            # maintenance reconciler so other devices do not retain a ready
            # asset after this request commits.
            from .sync_service import SyncService
            await SyncRepository(self.session).append_change(
                "mediaAsset", locked.id, "update", locked.version, SyncService._serialize(locked)
            )
            # The route commits this metadata transition before returning a
            # 404; raising here would roll the request transaction back.
            return None
        return await self.storage.create_download_url(asset.object_key)

    async def cleanup_expired_uploads(self, now: datetime) -> list[str]:
        """Delete expired pending objects and their metadata in one caller transaction."""
        expired = await self.repository.expired_pending(now)
        deleted_keys: list[str] = []
        for asset in expired:
            await self.storage.delete(asset.object_key)
            deleted_keys.append(asset.object_key)
            await self.session.delete(asset)
        return deleted_keys

    async def cleanup_orphan_objects(self, now: datetime) -> list[str]:
        """Remove aged objects that cannot be referenced by a media row.

        This covers a successful direct upload whose database transaction never
        committed. The age guard preserves an in-flight finalize request.
        """
        referenced = await self.repository.active_object_keys(now - timedelta(days=30))
        cutoff = now - timedelta(seconds=self.settings.media_upload_expiry_seconds)
        deleted_keys: list[str] = []
        for stored in await self.storage.list_objects(self.settings.media_object_prefix):
            if stored.object_key in referenced:
                continue
            if stored.last_modified is None or stored.last_modified > cutoff:
                continue
            await self.storage.delete(stored.object_key)
            deleted_keys.append(stored.object_key)
        return deleted_keys

    async def reconcile_ready_objects(self) -> list[UUID]:
        """Mark metadata whose object was lost; never return an invalid download URL."""
        missing: list[UUID] = []
        for asset in await self.repository.ready_assets():
            if not await self.storage.object_exists(asset.object_key):
                asset.status = "missing"
                asset.version += 1
                await self.session.flush()
                from .sync_service import SyncService
                await SyncRepository(self.session).append_change(
                    "mediaAsset", asset.id, "update", asset.version, SyncService._serialize(asset)
                )
                missing.append(asset.id)
        return missing

    @staticmethod
    def _validate_upload(mime_type: str, size_bytes: int, checksum: str, file_name: str | None) -> None:
        normalized_mime = mime_type.strip().lower()
        # This is the existing chat attachment allowlist, not a generic file
        # hosting endpoint. The Message validator binds each MIME to its kind.
        allowed_mime_types = {
            "image/jpeg", "image/png", "image/heic", "image/heif",
            "audio/aac", "audio/m4a", "audio/x-m4a", "audio/mp4", "audio/mpeg",
        } | set(CHAT_FILE_MIME_BY_EXTENSION.values())
        if normalized_mime not in allowed_mime_types:
            raise ValidationError("media MIME type is invalid")
        if normalized_mime in CHAT_FILE_MIME_BY_EXTENSION.values():
            extension = file_name.rsplit(".", 1)[-1].lower() if file_name and "." in file_name else ""
            if CHAT_FILE_MIME_BY_EXTENSION.get(extension) != normalized_mime:
                raise ValidationError("file name and MIME type do not match")
        if size_bytes < 0:
            raise ValidationError("media size is invalid")
        if re.fullmatch(r"[A-Fa-f0-9]{64}", checksum) is None:
            raise ValidationError("media checksum must be a SHA-256 hex digest")
