# FamilyApp future remote backend

Status: **Backend complete code path / iOS localOnly / 未运行 / 未验证服务可用**.

This is a FastAPI + async SQLAlchemy + PostgreSQL code path for a future opt-in
three-member sync deployment. It remains deliberately disconnected from the
shipping iOS Demo: iOS constructs only `LocalRepository` and performs no health
check, login, upload, WebSocket, or sync operation.

## Included layers

- `models/`: versioned/tombstoned business records, normalized agenda
  participants, reads/receipts and import-batch items, devices, refresh-token
  hashes, media metadata, processed mutations and ordered sync changes.
- `repositories/`, `services/`, `routers/`: async transaction boundaries,
  server-side permissions, rotating refresh sessions, optimistic mutations,
  bootstrap/pull/push, best-effort cursor notifications, and a private media
  storage abstraction. WebSocket contains notifications only; REST pull is the
  reliable data path.
- `alembic/versions/0001_remote_sync.py`: canonical initial schema revision;
  `0002_recovery_control_plane.py` adds non-replicated recovery credentials
  and one-use recovery authorizations. The older `migrations/0001_initial.sql`
  is intentionally marked obsolete.
- `.env.example`: placeholders only. Never commit a database URL or token
  secret. Absolute timestamps are PostgreSQL `timestamptz`; teaching calendar
  values remain civil dates in the configured family timezone.

## Private media storage

Media uses a private, optional S3-compatible bucket. Set
`FAMILYAPP_MEDIA_BACKEND=s3` plus the `FAMILYAPP_MEDIA_S3_*` values in
`.env.example` for AWS S3, Cloudflare R2, Backblaze B2, MinIO, or another
standard provider. `FAMILYAPP_MEDIA_S3_ENDPOINT_URL` is optional for AWS and
normally required for other providers; MinIO commonly uses `path` addressing.

The API stores generated object keys and metadata only. It issues short-lived
presigned PUT/GET URLs, verifies MIME type, byte length, metadata and SHA-256
on finalize, and never exposes a permanent public object URL. Leave the
backend `unconfigured` to keep core routes available while media routes return
an explicit 503. Cleanup service methods cover expired pending rows, aged
orphan objects, and ready rows whose object has disappeared; invoke them from a
future authenticated maintenance job rather than a request path.

The sync contract is local-first: clients commit locally, persist an outbox
mutation, then push idempotently. Pull cursors advance only after a complete
local application. Version conflicts and tombstone conflicts are explicit 409s;
the backend does not silently apply last-write-wins.

`FAMILYAPP_SYNC_RETENTION_DAYS` controls opportunistic acknowledged-prefix
cleanup. The scheduled data-retention pass caps change history at 30 days so
old location payloads leave with their snapshots. Offline cursors may expire;
the client must bootstrap on 409. Business rows remain durable independently
of this log. Deleted messages, notices, memos and agendas retain recoverable
content for 30 days; member/device/recovery state is never ordinary trash.

No FastAPI server, database, Alembic migration, object storage, WebSocket,
Docker, dependencies, or iOS remote connection was run in this change.

## Account recovery control plane

Recovery uses a client-generated BIP-39 phrase only to derive a separate
secret. PostgreSQL stores a versioned `recovery-v1` scrypt verifier, never the
phrase or the derived secret. A short-lived, single-use `RecoverySession` is
not a bearer or refresh token and cannot reach sync, chat, media, or location
routes. Password reset preserves the current mnemonic; new-device recovery
uses the normal Device + access/refresh issuance path; account takeover rotates
the verifier generation and revokes other devices and refresh sessions in the
same transaction. Recovery records are deliberately absent from SyncChange and
client backups.

## Invitation and member approval control plane

`FAMILYAPP_INVITE_CODE` only permits `POST /v1/auth/registrations` to create a
short-lived, installation-bound pending application. It never creates a
Member or bearer session. Any authenticated active member can review pending
requests at `/v1/members/join-requests`; approval atomically creates the UUID
Member and its member SyncChange. The applicant must then prove its stored
one-time registration capability from that same installation to activate the
existing Device/access/refresh session path. Pending records, their password
verifiers, and activation-token hashes are control-plane data: they never
enter SyncChange or client backup exports.
