#!/usr/bin/env bash
# Bootstrap a fresh Debian host from the published repository.
set -euo pipefail

REPOSITORY_URL="https://github.com/koajsj/familyapp.git"
INSTALL_DIR="/opt/familyapp"
PRIVILEGE=()

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ -r /etc/os-release ]] || fail "Debian /etc/os-release is unavailable."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || fail "This installer supports Debian only."

if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || fail "Run as root or install sudo."
    sudo -v || fail "Root permission is required."
    PRIVILEGE=(sudo)
fi
run_root() { "${PRIVILEGE[@]}" "$@"; }

command -v git >/dev/null 2>&1 || {
    run_root apt-get update
    run_root apt-get install -y --no-install-recommends ca-certificates git curl
}

if [[ -e "$INSTALL_DIR" ]]; then
    [[ -d "$INSTALL_DIR/.git" ]] || fail "$INSTALL_DIR exists but is not a Git checkout; inspect it manually."
    actual_origin="$(run_root git -C "$INSTALL_DIR" remote get-url origin 2>/dev/null || true)"
    [[ "$actual_origin" == "$REPOSITORY_URL" ]] || fail "$INSTALL_DIR has a different Git origin."
else
    run_root install -d -m 0755 /opt
    run_root git clone --branch main --single-branch "$REPOSITORY_URL" "$INSTALL_DIR"
fi

[[ -f "$INSTALL_DIR/deploy/bootstrap.sh" && -f "$INSTALL_DIR/deploy/init-env.sh" ]] ||
    fail "The checkout lacks the expected deployment scripts."
run_root bash "$INSTALL_DIR/deploy/init-env.sh"
run_root bash "$INSTALL_DIR/deploy/bootstrap.sh"
