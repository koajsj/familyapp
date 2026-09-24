# FamilyApp Debian VPS deployment

This is the single production path for the future FastAPI service. The iOS app
still ships with `AppRuntimeMode.localOnly`: deploying this server does not
make an iPhone log in, upload, sync, open WebSocket connections, or use media.

## Architecture and prerequisites

Only Caddy publishes ports 80/443. It obtains/renews HTTPS certificates,
redirects HTTP to HTTPS, and proxies REST and WebSocket traffic to the internal
FastAPI container. API port 8000 and PostgreSQL port 5432 are never published.
The Compose `local-db` profile stores PostgreSQL in `familyapp-postgres`; set an
external `DATABASE_URL` instead to avoid starting that profile. Private media
uses any S3-compatible provider when configured; PostgreSQL stores metadata,
not file bytes.

Before bootstrap, create DNS A/AAAA records for `API_DOMAIN` and open 80/443
(plus SSH) in both provider and host firewalls. On a fresh Debian VPS, run
the installer from an interactive SSH terminal. It asks for the API domain,
creates a private `.env` with random local database/JWT/account/invite secrets,
and delegates to the existing bootstrap script:

```bash
curl -fsSL https://raw.githubusercontent.com/koajsj/familyapp/main/install.sh | bash
```

The manual equivalent remains available:

```bash
sudo apt-get update && sudo apt-get install -y git
sudo git clone https://github.com/koajsj/familyapp.git /opt/familyapp
cd /opt/familyapp
sudo cp .env.example .env
sudo chmod 600 .env
sudo nano .env
sudo ./deploy/bootstrap.sh
```

`bootstrap.sh` verifies Debian/root access, installs missing Docker Engine and
Compose plugin, preserves `.env` and volumes, validates production secrets,
builds the image, waits for local PostgreSQL when selected, runs Alembic,
provisions fixed members only when remote auth is enabled, starts API/Caddy, and
requires external HTTPS `/health` and `/ready`. It never changes DNS or creates
a cloud account.

## Required configuration

Fill real values in VPS-only `.env`; it is ignored by Git and must be `0600`.
`APP_ENV=production`, `DEBUG=false`, `API_DOMAIN`, `ALLOWED_HOSTS`,
`DATABASE_URL`, `JWT_SECRET`, `FAMILYAPP_FAMILY_TIMEZONE`, and
`REMOTE_SYNC_ENABLED` are checked by scripts. `CORS_ORIGINS` is empty unless a
specific HTTPS web origin exists; wildcard hosts/origins are rejected.
When remote sync is enabled, replace the example `FAMILYAPP_INVITE_CODE` with a
strong private value; the deployment preflight rejects the example value.

For local PostgreSQL, retain host `db` in `DATABASE_URL` and set strong
`POSTGRES_DB`, `POSTGRES_USER`, and `POSTGRES_PASSWORD`. For hosted PostgreSQL,
replace the full URL; the local database profile will not start. S3 media uses
only the real `FAMILYAPP_MEDIA_S3_*` variables in the template. Keep its bucket
private and never commit JWT, database, S3, or member-password secrets.

## Operations

```bash
sudo ./deploy/healthcheck.sh
sudo ./deploy/update.sh                 # configured remote/branch
sudo ./deploy/update.sh <git-sha>       # SHA reachable from DEPLOY_REMOTE/DEPLOY_BRANCH
sudo ./deploy/backup.sh
sudo ./deploy/rollback.sh [old-git-sha]
docker compose --env-file .env -f docker-compose.prod.yml ps
docker compose --env-file .env -f docker-compose.prod.yml logs -f api caddy
```

`update.sh` takes a non-blocking deployment lock, rejects modified/staged/
untracked checkouts, checks disk space and target ancestry, makes a backup,
builds, migrates, restarts, health-checks, and records a secret-free result in
`/opt/familyapp/deployments/`. It never uses `git pull && docker compose up`.
On a post-migration failure it blocks automatic code rollback unless
`ROLLBACK_SCHEMA_COMPATIBLE=true` was deliberately confirmed. No script runs
`alembic downgrade`.

Backups are gzipped SQL files in `BACKUP_DIR`, first locally and then optionally
to `S3_BACKUP_URI`. Daily/weekly/monthly retention uses
`BACKUP_DAILY_RETENTION`, `BACKUP_WEEKLY_RETENTION`, and
`BACKUP_MONTHLY_RETENTION`; upload failure leaves the local archive intact. To
restore a local database, stop API writes, take a fresh backup, then run a
reviewed command such as:

```bash
gunzip -c <archive.sql.gz> | docker compose --env-file .env -f docker-compose.prod.yml exec -T db psql -U <user> -d <database>
```

Restore is intentionally manual and should first be rehearsed on a disposable database.

## GitHub Actions and maintenance timers

Production updates are triggered manually with the GitHub Actions workflow,
which invokes this same `update.sh` over SSH. Publishing to `main` alone does
not deploy. Actions does not duplicate backup, migration, rollback, or health logic.
Set only `VPS_HOST`, `VPS_USER`, `VPS_PORT`, `VPS_SSH_KEY`, and pinned
`VPS_KNOWN_HOSTS` in GitHub Secrets. Install
`deploy/sudoers/familyapp-deploy` with `visudo` after replacing `DEPLOY_USER`;
do not grant that account a general root shell.

Templates in `deploy/systemd/` schedule `backup.sh` and `media-cleanup.sh`.
After reviewing paths, install them with `sudo cp deploy/systemd/*.service
deploy/systemd/*.timer /etc/systemd/system/`, then `sudo systemctl daemon-reload`
and enable the chosen timers. The cleanup timer runs both the 30-day data
retention pass and existing MediaStorage cleanup. It does not use public API
requests and exits cleanly when media storage is unconfigured. Docker restart
policies recover Caddy/API/local PostgreSQL after
a VPS reboot; run `healthcheck.sh` afterwards.

## Troubleshooting and verification boundary

For connection failures, check DNS, firewall rules, `docker compose ... ps`,
and Caddy/API/DB logs; do not expose 8000 or 5432 to diagnose them. Disk-full
preflight requires `MIN_FREE_DISK_MB`; clear only reviewed Docker logs/backups.
For external DB failures, verify its network/TLS/allowlist separately. For S3,
verify private-bucket policy, endpoint, CORS for direct PUT, and credentials.

This repository has only static deployment preparation. Do not treat it as a
successful production deployment until a real VPS has passed HTTPS, migration,
backup/restore rehearsal, object-storage, permission, and recovery checks.
