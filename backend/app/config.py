"""Configuration is read only when the future API process starts."""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    database_url: str
    access_token_secret: str
    app_env: str
    debug: bool
    api_domain: str
    allowed_hosts: tuple[str, ...]
    cors_origins: tuple[str, ...]
    openapi_enabled: bool
    max_request_bytes: int
    remote_sync_enabled: bool
    access_token_ttl_seconds: int
    refresh_token_ttl_seconds: int
    recovery_session_ttl_seconds: int
    sync_retention_days: int
    family_timezone: str
    media_backend: str
    media_s3_bucket: str | None
    media_s3_region: str | None
    media_s3_endpoint_url: str | None
    media_s3_access_key_id: str | None
    media_s3_secret_access_key: str | None
    media_s3_session_token: str | None
    media_s3_addressing_style: str
    media_s3_presign_seconds: int
    media_upload_expiry_seconds: int
    media_object_prefix: str

    @classmethod
    def from_environment(cls) -> "Settings":
        def flag(name: str, default: bool) -> bool:
            return os.environ.get(name, str(default)).strip().lower() in {"1", "true", "yes"}

        def csv(name: str) -> tuple[str, ...]:
            return tuple(value.strip() for value in os.environ.get(name, "").split(",") if value.strip())

        retention_days = int(os.environ.get("FAMILYAPP_SYNC_RETENTION_DAYS", "90"))
        if retention_days < 0:
            raise ValueError("FAMILYAPP_SYNC_RETENTION_DAYS must be zero or greater")
        media_backend = os.environ.get("FAMILYAPP_MEDIA_BACKEND", "unconfigured").strip().lower()
        if media_backend not in {"unconfigured", "s3"}:
            raise ValueError("FAMILYAPP_MEDIA_BACKEND must be unconfigured or s3")
        media_s3_bucket = os.environ.get("FAMILYAPP_MEDIA_S3_BUCKET") or None
        if media_backend == "s3" and media_s3_bucket is None:
            raise ValueError("FAMILYAPP_MEDIA_S3_BUCKET is required when media storage is enabled")
        access_key = os.environ.get("FAMILYAPP_MEDIA_S3_ACCESS_KEY_ID") or None
        secret_key = os.environ.get("FAMILYAPP_MEDIA_S3_SECRET_ACCESS_KEY") or None
        if (access_key is None) != (secret_key is None):
            raise ValueError("S3 access key ID and secret access key must be configured together")
        addressing_style = os.environ.get("FAMILYAPP_MEDIA_S3_ADDRESSING_STYLE", "auto").strip().lower()
        if addressing_style not in {"auto", "path", "virtual"}:
            raise ValueError("FAMILYAPP_MEDIA_S3_ADDRESSING_STYLE must be auto, path, or virtual")
        presign_seconds = int(os.environ.get("FAMILYAPP_MEDIA_S3_PRESIGN_SECONDS", "900"))
        upload_expiry_seconds = int(os.environ.get("FAMILYAPP_MEDIA_UPLOAD_EXPIRY_SECONDS", "86400"))
        if not 60 <= presign_seconds <= 3600:
            raise ValueError("FAMILYAPP_MEDIA_S3_PRESIGN_SECONDS must be 60...3600")
        if not 300 <= upload_expiry_seconds <= 604800:
            raise ValueError("FAMILYAPP_MEDIA_UPLOAD_EXPIRY_SECONDS must be 300...604800")
        recovery_session_ttl_seconds = int(os.environ.get("FAMILYAPP_RECOVERY_SESSION_TTL_SECONDS", "600"))
        if not 60 <= recovery_session_ttl_seconds <= 3_600:
            raise ValueError("FAMILYAPP_RECOVERY_SESSION_TTL_SECONDS must be 60...3600")
        object_prefix = os.environ.get("FAMILYAPP_MEDIA_OBJECT_PREFIX", "familyapp/private").strip("/")
        if not object_prefix:
            raise ValueError("FAMILYAPP_MEDIA_OBJECT_PREFIX must not be empty")

        return cls(
            database_url=os.environ.get("DATABASE_URL", os.environ.get("FAMILYAPP_DATABASE_URL", "postgresql+asyncpg://unconfigured")),
            access_token_secret=os.environ.get("JWT_SECRET", os.environ.get("FAMILYAPP_ACCESS_TOKEN_SECRET", "unconfigured-development-secret")),
            app_env=os.environ.get("APP_ENV", "development"),
            debug=flag("DEBUG", False),
            api_domain=os.environ.get("API_DOMAIN", ""),
            allowed_hosts=csv("ALLOWED_HOSTS"),
            cors_origins=csv("CORS_ORIGINS"),
            openapi_enabled=flag("OPENAPI_ENABLED", False),
            max_request_bytes=int(os.environ.get("MAX_REQUEST_BYTES", "10485760")),
            remote_sync_enabled=flag("REMOTE_SYNC_ENABLED", False),
            access_token_ttl_seconds=int(os.environ.get("FAMILYAPP_ACCESS_TOKEN_TTL_SECONDS", "900")),
            refresh_token_ttl_seconds=int(os.environ.get("FAMILYAPP_REFRESH_TOKEN_TTL_SECONDS", "2592000")),
            recovery_session_ttl_seconds=recovery_session_ttl_seconds,
            # Zero deliberately disables pruning; positive values retain
            # acknowledged changes for at least this many days.
            sync_retention_days=retention_days,
            family_timezone=os.environ.get("FAMILYAPP_FAMILY_TIMEZONE", "Asia/Shanghai"),
            media_backend=media_backend,
            media_s3_bucket=media_s3_bucket,
            media_s3_region=os.environ.get("FAMILYAPP_MEDIA_S3_REGION") or None,
            media_s3_endpoint_url=os.environ.get("FAMILYAPP_MEDIA_S3_ENDPOINT_URL") or None,
            media_s3_access_key_id=access_key,
            media_s3_secret_access_key=secret_key,
            media_s3_session_token=os.environ.get("FAMILYAPP_MEDIA_S3_SESSION_TOKEN") or None,
            media_s3_addressing_style=addressing_style,
            media_s3_presign_seconds=presign_seconds,
            media_upload_expiry_seconds=upload_expiry_seconds,
            media_object_prefix=object_prefix,
        )
