#!/usr/bin/env bash
# Scheduled-only wrapper around app.maintenance; it never calls a public API.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

require_root
for command in docker flock; do require_command "$command"; done
validate_environment
prepare_directories
exec 7>"$STATE_DIR/media-cleanup.lock"
flock -n 7 || die "Another media cleanup is already running."

compose run --rm api python -m app.maintenance data-retention
compose run --rm api python -m app.maintenance media-cleanup
