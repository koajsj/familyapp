#!/usr/bin/env bash
# Initialize only missing production configuration. Existing .env is never rewritten.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENV_FILE="$ROOT_DIR/.env"
TEMPLATE="$ROOT_DIR/.env.example"
(( EUID == 0 )) || { printf 'ERROR: Run init-env.sh as root.\n' >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { printf 'ERROR: Missing .env.example.\n' >&2; exit 1; }

if [[ -f "$ENV_FILE" ]]; then
    printf 'Existing .env preserved. Review its required production settings before bootstrap.\n'
    exit 0
fi

if [[ ! -t 2 ]]; then
    printf 'ERROR: An interactive terminal is required to enter API_DOMAIN. Create a private .env manually, then rerun.\n' >&2
    exit 1
fi

umask 077
CURRENT_TEMP="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
cp "$TEMPLATE" "$CURRENT_TEMP"
chmod 600 "$CURRENT_TEMP"
cleanup_temp() { if [[ -f "$CURRENT_TEMP" ]]; then rm -f -- "$CURRENT_TEMP"; fi; }
trap cleanup_temp EXIT

set_entry() {
    local key="$1" value="$2" line found=0 next_temp
    next_temp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$key="* ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$next_temp"
            found=1
        else
            printf '%s\n' "$line" >> "$next_temp"
        fi
    done < "$CURRENT_TEMP"
    if (( ! found )); then printf '%s=%s\n' "$key" "$value" >> "$next_temp"; fi
    chmod 600 "$next_temp"
    mv -f "$next_temp" "$CURRENT_TEMP"
}

random_hex() { od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'; }

printf 'Public API domain (for example api.your-domain.cn): ' > /dev/tty
IFS= read -r domain < /dev/tty
[[ "$domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ && "$domain" != *example.com* ]] || {
    printf 'ERROR: Enter a real DNS domain. No .env was created.\n' >&2
    exit 1
}

database_password="$(random_hex 24)"
set_entry API_DOMAIN "$domain"
set_entry ALLOWED_HOSTS "$domain"
set_entry POSTGRES_PASSWORD "$database_password"
set_entry DATABASE_URL "postgresql+asyncpg://familyapp:${database_password}@db:5432/familyapp"
set_entry JWT_SECRET "$(random_hex 48)"
set_entry FAMILYAPP_FIXED_MEMBER_PASSWORD "$(random_hex 24)"
set_entry FAMILYAPP_INVITE_CODE "$(random_hex 16)"
ln "$CURRENT_TEMP" "$ENV_FILE" || { printf 'ERROR: .env already exists; it was not overwritten.\n' >&2; exit 1; }
printf 'Private .env initialized. Configure DNS, optional media/backup settings, and firewall rules before bootstrap.\n'
