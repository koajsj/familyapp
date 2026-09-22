#!/usr/bin/env bash
# Safe code-only rollback. Alembic downgrade is intentionally never invoked.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

require_root
for command in docker git curl flock; do require_command "$command"; done
validate_environment
prepare_directories

pre_migration=false
held_lock=false
if [[ "${1:-}" == "--held-lock" ]]; then
    held_lock=true
    shift
fi
if [[ "${1:-}" == "--pre-migration" ]]; then
    pre_migration=true
    shift
fi

target="${1:-$(last_successful_commit)}"
[[ -n "$target" ]] || die "No previous successful commit was recorded."
if [[ "$pre_migration" != true ]]; then
    [[ "$(env_value ROLLBACK_SCHEMA_COMPATIBLE)" == "true" ]] || die "Refusing code rollback: database backward compatibility has not been explicitly confirmed. No Alembic downgrade is automatic."
fi
if [[ "$held_lock" != true ]]; then
    exec 9>"$STATE_DIR/deploy.lock"
    flock -n 9 || die "Another deployment is already running."
fi

ensure_clean_checkout
require_disk_space
previous="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"
target="$(git -C "$ROOT_DIR" rev-parse --verify "${target}^{commit}")"
branch="$(deployment_branch)"
rollback_failed() {
    local status="$?"
    record_deployment_history rollback-failure "$branch" "$previous" "$target" || true
    printf 'Code rollback failed (exit %s); no schema downgrade was attempted.\n' "$status" >&2
    exit "$status"
}
trap rollback_failed ERR

wait_for_local_database
git -C "$ROOT_DIR" checkout --detach "$target"
compose build api
compose up -d api caddy
"$ROOT_DIR/deploy/healthcheck.sh"
record_successful_commit "$target"
record_deployment_history rollback-success "$branch" "$previous" "$target"
trap - ERR
info "Code rollback completed. Database schema was not downgraded."
