#!/usr/bin/env bash
# First-run Debian VPS deployment. Clone https://github.com/koajsj/familyapp.git
# into /opt/familyapp first; this script never overwrites .env or removes volumes.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

require_root
install_prerequisites
for command in docker git curl flock; do require_command "$command"; done
ensure_clean_checkout
ensure_expected_origin
validate_environment
install_optional_clients
prepare_directories
require_disk_space

target="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"
branch="$(deployment_branch)"
bootstrap_failed() {
    local status="$?"
    record_deployment_history failure "$branch" "none" "$target" || true
    printf 'Bootstrap failed (exit %s). Existing volumes and .env were not removed.\n' "$status" >&2
    exit "$status"
}
trap bootstrap_failed ERR

wait_for_local_database
compose build api
compose run --rm migrate
if [[ "$(env_value REMOTE_SYNC_ENABLED)" == "true" ]]; then
    compose run --rm api python -m app.provisioning
fi
compose up -d api caddy
"$ROOT_DIR/deploy/healthcheck.sh"
record_successful_commit "$target"
record_deployment_history success "$branch" "none" "$target"
trap - ERR
info "Bootstrap completed. Only ports 80 and 443 are published by Compose."
