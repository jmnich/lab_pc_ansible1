#!/usr/bin/env bash
#
# One-time setup for a lab laptop. Run with sudo from a checkout of this
# repository:
#
#     sudo scripts/bootstrap.sh
#
# The script is idempotent: running it twice is safe.

set -euo pipefail

# The public HTTPS clone URL of this repository. This is the ONLY place
# the URL is configured; the systemd service unit is generated from it
# below at bootstrap time.
REPO_URL="https://github.com/jmnich/lab_pc_ansible1.git"

# Never let git prompt for credentials (the repo is public); fail instead.
export GIT_TERMINAL_PROMPT=0

PULL_DIR="/var/lib/ansible-pull"
SERVICE_SRC="files/ansible-pull.service"
TIMER_SRC="files/ansible-pull.timer"
SERVICE_DST="/etc/systemd/system/ansible-pull.service"
TIMER_DST="/etc/systemd/system/ansible-pull.timer"

log()  { printf '[bootstrap] %s\n' "$*"; }
fail() { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

trap 'fail "bootstrap failed at line $LINENO"' ERR

# --- 0. Sanity checks -------------------------------------------------------

[ "$(id -u)" -eq 0 ] || fail "must be run as root (sudo scripts/bootstrap.sh)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

[ -f "$SERVICE_SRC" ]    || fail "missing $SERVICE_SRC (run from a checkout of the repository)"
[ -f "$TIMER_SRC" ]      || fail "missing $TIMER_SRC (run from a checkout of the repository)"
[ -f local.yml ]         || fail "missing local.yml (run from a checkout of the repository)"
[ -f requirements.yml ]  || fail "missing requirements.yml (run from a checkout of the repository)"

# --- 1. Install ansible and git --------------------------------------------

log "updating apt cache and installing ansible + git"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ansible git

command -v ansible-pull >/dev/null 2>&1 || fail "ansible-pull not found after installing ansible"

# Ensure the community.general collection is available (needed by the
# flatpak_apps role). Prefer the distro package if it exists; otherwise
# install the pinned version from requirements.yml (compatible with the
# ansible-core shipped by the Mint/Ubuntu base).
if apt-cache show ansible-collection-community-general >/dev/null 2>&1; then
    log "installing community.general from the distro package"
    DEBIAN_FRONTEND=noninteractive apt-get install -y ansible-collection-community-general
elif ! ansible-galaxy collection list 2>/dev/null | grep -q '^community\.general'; then
    log "installing pinned collections from requirements.yml"
    ansible-galaxy collection install -r requirements.yml
fi

# --- 2. Create the pull directory -------------------------------------------

log "creating $PULL_DIR"
mkdir -p "$PULL_DIR"

# --- 3. Install systemd units (substituting REPO_URL into the service) ------

log "installing systemd units (REPO_URL=$REPO_URL)"
# Escape sed replacement metacharacters (& and the | delimiter) in the URL.
REPO_URL_ESCAPED="$(printf '%s' "$REPO_URL" | sed 's/[&|]/\\&/g')"
sed "s|REPO_URL|$REPO_URL_ESCAPED|g" "$SERVICE_SRC" > "$SERVICE_DST"
install -m 0644 "$TIMER_SRC" "$TIMER_DST"
chmod 0644 "$SERVICE_DST"

# --- 4. Reload systemd ------------------------------------------------------

log "reloading systemd"
systemctl daemon-reload

# --- 5. Apply the configuration once, immediately ---------------------------
# Start the service (not a second manual ansible-pull) so the converge and
# the timer can never overlap on the same pull directory / apt locks.

log "running ansible-pull once via ansible-pull.service to converge now"
systemctl start ansible-pull.service

# --- 6. Enable the timer for recurring runs ---------------------------------
# Enabled only after the manual converge finished, so the first timer tick
# cannot race with it.

log "enabling ansible-pull.timer (every hour)"
systemctl enable --now ansible-pull.timer

log "SUCCESS: laptop is configured. ansible-pull will re-apply every hour."
log "Check status with: systemctl status ansible-pull.service"
