#!/usr/bin/env bash
#
# install-docker-in-ubuntu-26.sh
#
# Bootstraps Docker Engine + compose plugin on a fresh Ubuntu 26.04 (Resolute) host.
# Non-interactive, idempotent. Safe to re-run.
#
# All install/config commands are taken verbatim from the official Docker docs:
#   - https://docs.docker.com/engine/install/ubuntu/
#   - https://docs.docker.com/engine/install/linux-postinstall/
#   - https://docs.docker.com/engine/logging/drivers/json-file/
#
# Usage:
#   chmod +x install-docker-in-ubuntu-26.sh
#   sudo ./install-docker-in-ubuntu-26.sh       # preferred — SUDO_USER is set
#   ./install-docker-in-ubuntu-26.sh            # also fine — script re-execs itself with sudo
#

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ─── Colors (TTY-aware) ────────────────────────────────────────────────────
if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_BLUE=$'\033[34m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_DIM=$'\033[2m'
    SYM_ARROW="▶"
    SYM_OK="✔"
    SYM_WARN="⚠"
    SYM_FAIL="✖"
else
    C_RESET='' C_BOLD='' C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_DIM=''
    SYM_ARROW=">"
    SYM_OK="OK"
    SYM_WARN="!!"
    SYM_FAIL="XX"
fi

# ─── Progress helpers ──────────────────────────────────────────────────────
TOTAL_STEPS=7
STEP_START_EPOCH=0

step_start() {
    local n="$1" label="$2"
    STEP_START_EPOCH=$SECONDS
    printf '\n%s%s [%s/%s] %s%s\n' "$C_BLUE$C_BOLD" "$SYM_ARROW" "$n" "$TOTAL_STEPS" "$label" "$C_RESET"
}

step_done() {
    local n="$1"
    local elapsed=$((SECONDS - STEP_START_EPOCH))
    printf '%s%s [%s/%s] Done in %ds%s\n' "$C_GREEN" "$SYM_OK" "$n" "$TOTAL_STEPS" "$elapsed" "$C_RESET"
}

info()  { printf '%s  %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
warn()  { printf '%s%s %s%s\n' "$C_YELLOW" "$SYM_WARN" "$*" "$C_RESET"; }
fail()  { printf '%s%s %s%s\n' "$C_RED" "$SYM_FAIL" "$*" "$C_RESET" >&2; exit 1; }

on_error() {
    local exit_code=$?
    local line=${BASH_LINENO[0]}
    local cmd=${BASH_COMMAND}
    printf '\n%s%s FAILED at line %d: %s (exit %d)%s\n' \
        "$C_RED$C_BOLD" "$SYM_FAIL" "$line" "$cmd" "$exit_code" "$C_RESET" >&2
}
trap on_error ERR

# ─── Preflight ─────────────────────────────────────────────────────────────
# Re-exec with sudo if not root.
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        info "Elevating with sudo..."
        exec sudo --preserve-env=TARGET_USER "$0" "$@"
    else
        fail "This script must run as root, and sudo is not available."
    fi
fi

# Verify Ubuntu 26.04 (Resolute).
if [ ! -r /etc/os-release ]; then
    fail "Cannot read /etc/os-release — unsupported OS."
fi
# shellcheck disable=SC1091
. /etc/os-release
if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "26.04" ]; then
    fail "This script only supports Ubuntu 26.04 (Resolute). Detected: ${PRETTY_NAME:-unknown}"
fi
info "OS: $PRETTY_NAME — supported."

# Resolve the user to add to the docker group.
# Priority: $SUDO_USER (real user who invoked sudo) > $TARGET_USER env > none.
TARGET_USER="${SUDO_USER:-${TARGET_USER:-}}"
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" = "root" ]; then
    TARGET_USER=""
fi
if [ -n "$TARGET_USER" ]; then
    info "Docker group will be granted to: $TARGET_USER"
else
    warn "No non-root user detected (no SUDO_USER, no TARGET_USER env). Docker group step will be skipped."
fi

# ─── Step 1/7 — Uninstall conflicting packages ─────────────────────────────
# Verbatim form from https://docs.docker.com/engine/install/ubuntu/,
# guarded so it's a no-op when no conflicting packages are installed.
step_start 1 "Removing conflicting packages (if any)"
CONFLICT_PKGS=$(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc 2>/dev/null | cut -f1 || true)
if [ -n "$CONFLICT_PKGS" ]; then
    # shellcheck disable=SC2086
    apt-get remove -y $CONFLICT_PKGS
else
    info "No conflicting packages present."
fi
step_done 1

# ─── Step 2/7 — Set up Docker's apt repository ─────────────────────────────
# Verbatim from https://docs.docker.com/engine/install/ubuntu/.
step_start 2 "Setting up Docker's apt repository"
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
step_done 2

# ─── Step 3/7 — Install Docker Engine + plugins ────────────────────────────
# Package list from https://docs.docker.com/engine/install/ubuntu/.
step_start 3 "Installing Docker Engine, CLI, containerd, Buildx, Compose"
apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
step_done 3

# ─── Step 4/7 — Configure log rotation via /etc/docker/daemon.json ─────────
# Config from https://docs.docker.com/engine/logging/drivers/json-file/.
# Idempotent: only writes if missing or our exact expected content; will
# NOT overwrite a daemon.json that contains unknown (user-customized) config.
step_start 4 "Configuring log rotation (/etc/docker/daemon.json)"
DAEMON_JSON=/etc/docker/daemon.json
DAEMON_JSON_CONTENT='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}'
RESTART_DOCKER=0
install -m 0755 -d /etc/docker
if [ ! -f "$DAEMON_JSON" ]; then
    printf '%s\n' "$DAEMON_JSON_CONTENT" > "$DAEMON_JSON"
    chmod 0644 "$DAEMON_JSON"
    RESTART_DOCKER=1
    info "Wrote $DAEMON_JSON."
elif diff -q <(printf '%s\n' "$DAEMON_JSON_CONTENT") "$DAEMON_JSON" >/dev/null 2>&1; then
    info "$DAEMON_JSON already matches expected configuration."
else
    warn "$DAEMON_JSON exists with custom content — not overwriting. Please verify log rotation manually."
fi

if [ "$RESTART_DOCKER" -eq 1 ] && systemctl is-active --quiet docker.service; then
    info "Restarting docker.service to apply logging config..."
    systemctl restart docker.service
fi
step_done 4

# ─── Step 5/7 — Enable services on boot ────────────────────────────────────
# Based on https://docs.docker.com/engine/install/linux-postinstall/.
# Plain `enable` (not `--now`) — services are already active after install.
step_start 5 "Enabling docker + containerd on boot"
systemctl enable docker.service
systemctl enable containerd.service
step_done 5

# ─── Step 6/7 — Add user to docker group ───────────────────────────────────
# From https://docs.docker.com/engine/install/linux-postinstall/.
step_start 6 "Configuring docker group membership"
if ! getent group docker >/dev/null; then
    groupadd docker
fi
if [ -n "$TARGET_USER" ]; then
    if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
        info "User '$TARGET_USER' is already in the docker group."
    else
        usermod -aG docker "$TARGET_USER"
        info "Added '$TARGET_USER' to the docker group. Log out and back in to apply."
    fi
else
    warn "Skipping docker-group step — no target user resolved."
fi
step_done 6

# ─── Step 7/7 — Verification ───────────────────────────────────────────────
step_start 7 "Running verification checks"

VERIFY_FAILED=0
VERIFY_WARNED=0

print_row() {
    # $1 = status tag [ OK ] / [WARN] / [FAIL] / [SKIP]
    # $2 = label
    # $3 = detail
    local status="$1" label="$2" detail="$3" color
    case "$status" in
        "[ OK ]") color="$C_GREEN"  ;;
        "[WARN]") color="$C_YELLOW" ;;
        "[FAIL]") color="$C_RED"    ;;
        "[SKIP]") color="$C_DIM"    ;;
        *)        color=""          ;;
    esac
    printf '  %s%s%s  %-32s %s\n' "$color" "$status" "$C_RESET" "$label" "$detail"
}

printf '\n%s─── Verification ─────────────────────────────────────────%s\n' "$C_BOLD" "$C_RESET"

# 1. docker --version
if DOCKER_VER=$(docker --version 2>/dev/null); then
    print_row "[ OK ]" "docker --version" "$DOCKER_VER"
else
    print_row "[FAIL]" "docker --version" "command not found"
    VERIFY_FAILED=1
fi

# 2. docker compose version
if COMPOSE_VER=$(docker compose version 2>/dev/null); then
    print_row "[ OK ]" "docker compose version" "$COMPOSE_VER"
else
    print_row "[FAIL]" "docker compose version" "compose plugin missing"
    VERIFY_FAILED=1
fi

# 3+4. service enabled + active
for svc in docker.service containerd.service; do
    enabled_state=$(systemctl is-enabled "$svc" 2>/dev/null || echo "?")
    active_state=$(systemctl is-active "$svc" 2>/dev/null || echo "?")
    if [ "$enabled_state" = "enabled" ] && [ "$active_state" = "active" ]; then
        print_row "[ OK ]" "$svc" "enabled, active"
    else
        print_row "[FAIL]" "$svc" "enabled=$enabled_state, active=$active_state"
        VERIFY_FAILED=1
    fi
done

# 5. daemon.json contents
if [ -f "$DAEMON_JSON" ] \
    && grep -q '"log-driver": *"json-file"' "$DAEMON_JSON" \
    && grep -q '"max-size": *"10m"' "$DAEMON_JSON" \
    && grep -q '"max-file": *"3"' "$DAEMON_JSON"; then
    print_row "[ OK ]" "/etc/docker/daemon.json" "json-file, 10m x 3"
else
    print_row "[WARN]" "/etc/docker/daemon.json" "custom or missing rotation keys"
    VERIFY_WARNED=1
fi

# 6. hello-world run (as root; leaves host clean)
if docker run --rm hello-world >/dev/null 2>&1; then
    print_row "[ OK ]" "hello-world run" "exit 0"
    docker image rm hello-world >/dev/null 2>&1 || true
else
    print_row "[FAIL]" "hello-world run" "engine could not run container"
    VERIFY_FAILED=1
fi

# 7. target user in docker group (warn-only — re-login is required anyway)
if [ -n "$TARGET_USER" ]; then
    if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        print_row "[WARN]" "user '$TARGET_USER' in docker grp" "re-login required to activate"
        VERIFY_WARNED=1
    else
        print_row "[FAIL]" "user '$TARGET_USER' in docker grp" "not a member"
        VERIFY_FAILED=1
    fi
else
    print_row "[SKIP]" "docker group membership" "no target user"
fi

# 8. compose file sanity (skip if not in the project dir)
if [ -f "docker-compose.prod.yml" ]; then
    if docker compose -f docker-compose.prod.yml config -q >/dev/null 2>&1; then
        print_row "[ OK ]" "docker-compose.prod.yml" "parses clean"
    else
        print_row "[WARN]" "docker-compose.prod.yml" "parse errors — run inside project dir"
        VERIFY_WARNED=1
    fi
else
    print_row "[SKIP]" "docker-compose.prod.yml" "not in CWD — skipping"
fi

printf '%s──────────────────────────────────────────────────────────%s\n' "$C_BOLD" "$C_RESET"
step_done 7

# ─── Final summary ─────────────────────────────────────────────────────────
printf '\n'
if [ "$VERIFY_FAILED" -eq 1 ]; then
    printf '%s%s Installation completed with failures. Review the verification table above.%s\n' \
        "$C_RED$C_BOLD" "$SYM_FAIL" "$C_RESET"
    exit 1
fi

printf '%s%s Docker is installed and configured.%s\n' "$C_GREEN$C_BOLD" "$SYM_OK" "$C_RESET"
if [ -n "$TARGET_USER" ]; then
    printf '\n%sNext steps:%s\n' "$C_BOLD" "$C_RESET"
    printf '  1. Log out and log back in (or reboot) so ''%s'' picks up the docker group.\n' "$TARGET_USER"
    printf '  2. Verify without sudo:  %sdocker ps%s\n' "$C_DIM" "$C_RESET"
    printf '  3. From the project directory:  %sdocker compose -f docker-compose.prod.yml up -d%s\n' "$C_DIM" "$C_RESET"
fi
printf '\n%sTip: this script is idempotent — re-run it any time to reconcile config.%s\n' "$C_DIM" "$C_RESET"