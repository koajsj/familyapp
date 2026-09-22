#!/usr/bin/env bash
# PostgreSQL backup with local-first storage and conservative GFS retention.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

upload_backup_if_configured() {
    local archive="$1" destination endpoint access_key secret_key region
    destination="$(env_value S3_BACKUP_URI)"
    [[ -n "$destination" ]] || return 0
    [[ "$destination" == s3://* ]] || die "S3_BACKUP_URI must use the s3:// scheme."
    require_command aws
    endpoint="$(env_value S3_ENDPOINT_URL)"
    access_key="$(env_value AWS_ACCESS_KEY_ID)"
    secret_key="$(env_value AWS_SECRET_ACCESS_KEY)"
    region="$(env_or_default AWS_DEFAULT_REGION us-east-1)"
    if [[ -n "$access_key" || -n "$secret_key" ]]; then
        [[ -n "$access_key" && -n "$secret_key" ]] || die "Configure both AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY for backup upload."
    fi
    local -a endpoint_args=()
    [[ -n "$endpoint" ]] && endpoint_args=(--endpoint-url "$endpoint")
    if [[ -n "$access_key" ]]; then
        AWS_ACCESS_KEY_ID="$access_key" AWS_SECRET_ACCESS_KEY="$secret_key" AWS_DEFAULT_REGION="$region" \
            aws --only-show-errors "${endpoint_args[@]}" s3 cp "$archive" "${destination%/}/$(basename "$archive")"
    else
        AWS_DEFAULT_REGION="$region" aws --only-show-errors "${endpoint_args[@]}" s3 cp "$archive" "${destination%/}/$(basename "$archive")"
    fi
}

retain_backups() {
    local directory="$1" newest="$2" daily_limit weekly_limit monthly_limit
    daily_limit="$(env_or_default BACKUP_DAILY_RETENTION 7)"
    weekly_limit="$(env_or_default BACKUP_WEEKLY_RETENTION 4)"
    monthly_limit="$(env_or_default BACKUP_MONTHLY_RETENTION 12)"
    for value in "$daily_limit" "$weekly_limit" "$monthly_limit"; do
        [[ "$value" =~ ^[0-9]+$ ]] || die "Backup retention values must be non-negative integers."
    done

    local -a backups=()
    mapfile -t backups < <(find "$directory" -maxdepth 1 -type f -name 'familyapp-postgres-????????T??????Z.sql.gz' -printf '%f\n' | sort -r)
    local -A keep=() seen_daily=() seen_weekly=() seen_monthly=()
    keep["$(basename "$newest")"]=1
    local daily_count=0 weekly_count=0 monthly_count=0 name date_key week_key month_key
    for name in "${backups[@]}"; do
        date_key="${name:19:8}"
        [[ "$date_key" =~ ^[0-9]{8}$ ]] || continue
        week_key="$(date -u -d "$date_key" +%G-W%V)"
        month_key="${date_key:0:6}"
        if (( daily_count < daily_limit )) && [[ -z "${seen_daily[$date_key]:-}" ]]; then
            keep["$name"]=1; seen_daily["$date_key"]=1; ((daily_count += 1))
        fi
        if (( weekly_count < weekly_limit )) && [[ -z "${seen_weekly[$week_key]:-}" ]]; then
            keep["$name"]=1; seen_weekly["$week_key"]=1; ((weekly_count += 1))
        fi
        if (( monthly_count < monthly_limit )) && [[ -z "${seen_monthly[$month_key]:-}" ]]; then
            keep["$name"]=1; seen_monthly["$month_key"]=1; ((monthly_count += 1))
        fi
    done
    for name in "${backups[@]}"; do
        [[ -n "${keep[$name]:-}" ]] || rm -f -- "$directory/$name"
    done
}

require_root
for command in gzip flock; do require_command "$command"; done
validate_environment
prepare_directories
exec 8>"$STATE_DIR/backup.lock"
flock -n 8 || die "Another database backup is already running."
umask 077

backup_dir="$(backup_directory)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive="$backup_dir/familyapp-postgres-${timestamp}.sql.gz"
temporary_archive="$(mktemp "$backup_dir/.familyapp-postgres-${timestamp}.XXXXXX")"
database_url="$(env_value DATABASE_URL)"
cleanup_temporary() { rm -f -- "$temporary_archive"; }
trap cleanup_temporary EXIT

if uses_local_database; then
    compose exec -T db pg_dump -U "$(env_value POSTGRES_USER)" -d "$(env_value POSTGRES_DB)" | gzip -c >"$temporary_archive"
else
    require_command pg_dump
    pg_dump --dbname="${database_url/postgresql+asyncpg:/postgresql:}" | gzip -c >"$temporary_archive"
fi
[[ -s "$temporary_archive" ]] || die "Backup archive is empty."
mv -- "$temporary_archive" "$archive"
chmod 0600 "$archive"
trap - EXIT

# Upload happens only after a protected local archive exists. A failed upload
# therefore cannot remove the usable local backup or trigger retention.
upload_backup_if_configured "$archive"
retain_backups "$backup_dir" "$archive"
info "Backup created: $(basename "$archive")"
