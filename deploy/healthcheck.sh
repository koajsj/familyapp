#!/usr/bin/env bash
# Shared finite external HTTPS health check for bootstrap/update/rollback/CI.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

require_command curl
validate_environment
domain="$(current_domain)"
max_attempts="$(env_or_default HEALTHCHECK_RETRIES 12)"
interval="$(env_or_default HEALTHCHECK_INTERVAL 5)"
timeout="$(env_or_default HEALTHCHECK_TIMEOUT 15)"
[[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || die "HEALTHCHECK_RETRIES must be a positive integer."
[[ "$interval" =~ ^[1-9][0-9]*$ ]] || die "HEALTHCHECK_INTERVAL must be a positive integer."
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || die "HEALTHCHECK_TIMEOUT must be a positive integer."

for path in /health /ready; do
    success=false
    for attempt in $(seq 1 "$max_attempts"); do
        if curl --fail --silent --show-error --proto '=https' --connect-timeout "$timeout" --max-time "$timeout" "https://${domain}${path}" >/dev/null; then
            success=true
            break
        fi
        [[ "$attempt" -lt "$max_attempts" ]] && sleep "$interval"
    done
    [[ "$success" == true ]] || die "HTTPS health check failed for ${path} after ${max_attempts} attempts."
done
info "HTTPS /health and /ready are reachable."
