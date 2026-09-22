#!/usr/bin/env bash
# Shared deployment helpers. Source only from deploy/*.sh on the Debian VPS.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENV_FILE="$ROOT_DIR/.env"
COMPOSE_FILE="$ROOT_DIR/docker-compose.prod.yml"
STATE_DIR="/var/lib/familyapp-deploy"
DEPLOYMENT_HISTORY_DIR="$ROOT_DIR/deployments"
REPOSITORY_URL="https://github.com/koajsj/familyapp.git"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
require_root() { [[ "${EUID}" -eq 0 ]] || die "Run this script with sudo."; }
compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

env_value() {
    local key="$1"
    [[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE; copy .env.example and fill it first."
    sed -n -E "s|^[[:space:]]*${key}=(.*)$|\\1|p" "$ENV_FILE" | tail -n 1
}

env_or_default() {
    local key="$1" default="$2" value
    value="$(env_value "$key")"
    printf '%s' "${value:-$default}"
}

backup_directory() { env_or_default BACKUP_DIR "/var/backups/familyapp"; }
current_domain() { env_value API_DOMAIN; }
deployment_branch() { env_or_default DEPLOY_BRANCH main; }
deployment_remote() { env_or_default DEPLOY_REMOTE origin; }

is_placeholder() {
    local value="${1,,}"
    [[ -z "$value" || "$value" == *replace-with* || "$value" == *example* || "$value" == *changeme* || "$value" == *change-me* || "$value" == *unconfigured* || "$value" == *your-* ]]
}

is_obviously_weak_secret() {
    local value="${1,,}"
    is_placeholder "$value" && return 0
    case "$value" in
        qwer1234|password|password123|12345678|123456789|familyapp|familyapp123)
            return 0
            ;;
    esac
    return 1
}

require_non_placeholder() {
    local key="$1" minimum_length="${2:-1}" value
    value="$(env_value "$key")"
    [[ ${#value} -ge "$minimum_length" ]] && ! is_placeholder "$value" || die "Set a non-example $key."
}

require_secret() {
    local key="$1" minimum_length="$2" value
    value="$(env_value "$key")"
    [[ ${#value} -ge "$minimum_length" ]] && ! is_obviously_weak_secret "$value" || die "Set a strong non-example $key."
}

ensure_private_env_file() {
    [[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE; copy .env.example and fill it first."
    local mode
    mode="$(stat -c '%a' "$ENV_FILE")"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die "Cannot read permissions for $ENV_FILE."
    (( (8#$mode & 0077) == 0 )) || die "$ENV_FILE must not be readable by group or others (run chmod 600 .env)."
}

ensure_debian_host() {
    [[ -r /etc/os-release ]] || die "This bootstrap path supports Debian VPS hosts only."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "debian" ]] || die "This bootstrap path supports Debian VPS hosts only."
    [[ -n "${VERSION_CODENAME:-}" ]] || die "Debian VERSION_CODENAME is unavailable."
}

install_prerequisites() {
    "${EUID}" -eq 0 || die "Run bootstrap with sudo."
    ensure_debian_host
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl git gnupg util-linux

    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s\n' "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
        apt-get update
        apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    require_command docker
    docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable."
    systemctl enable --now docker
}

install_optional_clients() {
    "${EUID}" -eq 0 || die "Run bootstrap with sudo."
    if ! uses_local_database && ! command -v pg_dump >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends postgresql-client
    fi
    if [[ -n "$(env_value S3_BACKUP_URI)" ]] && ! command -v aws >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends awscli
    fi
}

ensure_clean_checkout() {
    git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Deployment directory is not a Git checkout."
    git -C "$ROOT_DIR" diff --quiet || die "Deployment checkout has unstaged changes."
    git -C "$ROOT_DIR" diff --cached --quiet || die "Deployment checkout has staged changes."
    [[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]] || die "Deployment checkout has untracked files."
}

ensure_expected_origin() {
    local remote actual
    remote="$(deployment_remote)"
    actual="$(git -C "$ROOT_DIR" remote get-url "$remote" 2>/dev/null || true)"
    [[ "$actual" == "$REPOSITORY_URL" ]] || die "Configured DEPLOY_REMOTE '$remote' must point to $REPOSITORY_URL."
}

require_disk_space() {
    local minimum available
    minimum="$(env_or_default MIN_FREE_DISK_MB 2048)"
    [[ "$minimum" =~ ^[0-9]+$ && "$minimum" -ge 256 ]] || die "MIN_FREE_DISK_MB must be an integer of at least 256."
    available="$(df -Pm "$ROOT_DIR" | awk 'NR == 2 { print $4 }')"
    [[ "$available" =~ ^[0-9]+$ ]] || die "Unable to determine free disk space."
    (( available >= minimum )) || die "Only ${available} MB is free; at least ${minimum} MB is required."
}

validate_environment() {
    ensure_private_env_file
    [[ "$(env_value APP_ENV)" == "production" ]] || die "APP_ENV must be production."
    [[ "$(env_value DEBUG)" == "false" ]] || die "DEBUG must be false."
    local domain allowed_hosts cors remote_enabled database_url openapi_enabled max_request_bytes
    domain="$(current_domain)"
    [[ "$domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ && "$domain" != *example.com* ]] || die "Set a real DNS API_DOMAIN, not an IP address or example domain."
    allowed_hosts="$(env_value ALLOWED_HOSTS)"
    [[ -n "$allowed_hosts" && "$allowed_hosts" != *"*"* && ",$allowed_hosts," == *",$domain,"* ]] || die "ALLOWED_HOSTS must include API_DOMAIN and must not use a wildcard."
    cors="$(env_value CORS_ORIGINS)"
    [[ "$cors" != *"*"* ]] || die "CORS_ORIGINS must not use a wildcard in production."
    openapi_enabled="$(env_value OPENAPI_ENABLED)"
    [[ "$openapi_enabled" == "true" || "$openapi_enabled" == "false" ]] || die "OPENAPI_ENABLED must be true or false."
    max_request_bytes="$(env_value MAX_REQUEST_BYTES)"
    [[ "$max_request_bytes" =~ ^[1-9][0-9]*$ ]] || die "MAX_REQUEST_BYTES must be a positive integer."
    database_url="$(env_value DATABASE_URL)"
    require_non_placeholder DATABASE_URL 24
    [[ "${database_url,,}" != *password* && "${database_url,,}" != *qwer1234* && "${database_url,,}" != *changeme* ]] || die "DATABASE_URL contains an obvious example or weak password."
    require_secret JWT_SECRET 32
    require_non_placeholder FAMILYAPP_FAMILY_TIMEZONE 3
    remote_enabled="$(env_value REMOTE_SYNC_ENABLED)"
    [[ "$remote_enabled" == "true" || "$remote_enabled" == "false" ]] || die "REMOTE_SYNC_ENABLED must be true or false."
    if [[ "$remote_enabled" == "true" ]]; then
        require_secret FAMILYAPP_FIXED_MEMBER_PASSWORD 12
    fi
    if uses_local_database; then
        require_non_placeholder POSTGRES_DB 1
        require_non_placeholder POSTGRES_USER 1
        require_secret POSTGRES_PASSWORD 16
    fi

    case "$(env_or_default FAMILYAPP_MEDIA_BACKEND unconfigured)" in
        unconfigured) ;;
        s3)
            require_non_placeholder FAMILYAPP_MEDIA_S3_BUCKET 3
            local access_key secret_key prefix
            access_key="$(env_value FAMILYAPP_MEDIA_S3_ACCESS_KEY_ID)"
            secret_key="$(env_value FAMILYAPP_MEDIA_S3_SECRET_ACCESS_KEY)"
            if [[ -n "$access_key" || -n "$secret_key" ]]; then
                [[ -n "$access_key" && -n "$secret_key" ]] || die "Configure both S3 access-key variables or neither when using an instance identity."
                ! is_placeholder "$access_key" && ! is_placeholder "$secret_key" || die "S3 access-key variables must not use example values."
            fi
            prefix="$(env_value FAMILYAPP_MEDIA_OBJECT_PREFIX)"
            [[ -n "$prefix" && "$prefix" != /* && "$prefix" != */ ]] || die "FAMILYAPP_MEDIA_OBJECT_PREFIX must be a non-empty relative prefix."
            ;;
        *) die "FAMILYAPP_MEDIA_BACKEND must be s3 or unconfigured." ;;
    esac
    compose config -q
}

uses_local_database() {
    local database_url
    database_url="$(env_value DATABASE_URL)"
    [[ "$database_url" =~ ^postgresql(\+asyncpg)?://.+@db(:[0-9]+)?/ ]]
}

wait_for_local_database() {
    uses_local_database || return 0
    compose --profile local-db up -d db
    local attempt
    for attempt in $(seq 1 24); do
        if compose exec -T db pg_isready -U "$(env_value POSTGRES_USER)" -d "$(env_value POSTGRES_DB)" >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
    done
    die "Local PostgreSQL did not become ready."
}

prepare_directories() {
    local backup_dir
    backup_dir="$(backup_directory)"
    [[ "$backup_dir" == /* && "$backup_dir" != "/" ]] || die "BACKUP_DIR must be an absolute non-root path."
    install -d -m 0700 "$STATE_DIR" "$backup_dir"
    install -d -m 0750 "$DEPLOYMENT_HISTORY_DIR"
}

last_successful_commit() {
    [[ -f "$STATE_DIR/last-successful-commit" ]] && sed -n '1p' "$STATE_DIR/last-successful-commit" || true
}

record_successful_commit() {
    local revision="$1"
    printf '%s\n' "$revision" >"$STATE_DIR/last-successful-commit"
    chmod 0600 "$STATE_DIR/last-successful-commit"
}

record_deployment_history() {
    local result="$1" branch="$2" previous="$3" target="$4" timestamp history_file
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    history_file="$DEPLOYMENT_HISTORY_DIR/${timestamp}-${result}-${target:0:12}.txt"
    {
        printf 'timestamp=%s\n' "$timestamp"
        printf 'result=%s\n' "$result"
        printf 'branch=%s\n' "$branch"
        printf 'previous_commit=%s\n' "$previous"
        printf 'target_commit=%s\n' "$target"
    } >"$history_file"
    chmod 0600 "$history_file"
}

resolve_deploy_target() {
    local requested="${1:-}" remote branch remote_ref resolved
    remote="$(deployment_remote)"
    branch="$(deployment_branch)"
    git -C "$ROOT_DIR" remote get-url "$remote" >/dev/null 2>&1 || die "Configured DEPLOY_REMOTE '$remote' does not exist."
    git -C "$ROOT_DIR" fetch --prune "$remote"
    remote_ref="refs/remotes/${remote}/${branch}"
    git -C "$ROOT_DIR" show-ref --verify --quiet "$remote_ref" || die "Configured deployment branch '${remote}/${branch}' was not fetched."
    if [[ -n "$requested" ]]; then
        [[ "$requested" =~ ^[0-9a-fA-F]{7,64}$ ]] || die "Target commit must be a Git SHA."
        resolved="$(git -C "$ROOT_DIR" rev-parse --verify "${requested}^{commit}")"
        git -C "$ROOT_DIR" merge-base --is-ancestor "$resolved" "$remote_ref" || die "Target commit is not reachable from ${remote}/${branch}."
    else
        resolved="$(git -C "$ROOT_DIR" rev-parse --verify "${remote_ref}^{commit}")"
    fi
    printf '%s\n' "$resolved"
}
