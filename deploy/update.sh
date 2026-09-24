#!/usr/bin/env bash
# The only manual/CI production update path. Never replace this with git pull.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

require_root
for command in docker git curl flock; do require_command "$command"; done
validate_environment
prepare_directories
exec 9>"$STATE_DIR/deploy.lock"
flock -n 9 || die "Another deployment is already running."
ensure_clean_checkout
ensure_expected_origin
require_disk_space

previous="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"
branch="$(deployment_branch)"
target="$(resolve_deploy_target "${1:-}")"
code_switched=false
migration_started=false

update_failed() {
    local status="$?"
    printf 'Deployment failed (exit %s).\n' "$status" >&2
    record_deployment_history failure "$branch" "$previous" "$target" || true
    if [[ "$code_switched" != true ]]; then
        printf 'No code checkout occurred; no rollback was attempted.\n' >&2
    elif [[ "$migration_started" == false || "$(env_value ROLLBACK_SCHEMA_COMPATIBLE)" == "true" ]]; then
        printf 'Attempting safe code rollback to the previous commit.\n' >&2
        local rollback_args=(--held-lock)
        [[ "$migration_started" == false ]] && rollback_args+=(--pre-migration)
        "$ROOT_DIR/deploy/rollback.sh" "${rollback_args[@]}" "$previous" || printf 'Automatic rollback also failed; inspect the server before retrying.\n' >&2
    else
        printf 'Migration may have run; automatic code rollback is blocked until schema compatibility is confirmed.\n' >&2
    fi
    exit "$status"
}
trap update_failed ERR

# A backup failure deliberately stops here before changing the checkout.
wait_for_local_database
"$ROOT_DIR/deploy/backup.sh"
require_disk_space
git -C "$ROOT_DIR" checkout --detach "$target"
code_switched=true
wait_for_local_database
compose build api
migration_started=true
compose run --rm migrate
compose up -d api caddy
"$ROOT_DIR/deploy/healthcheck.sh"
record_successful_commit "$target"
record_deployment_history success "$branch" "$previous" "$target"
trap - ERR
info "Update completed successfully."
