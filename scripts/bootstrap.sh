#!/usr/bin/env bash
#
# One-time setup for a lab laptop. Run with sudo from a checkout of this
# repository:
#
#     sudo scripts/bootstrap.sh
#
# The script is idempotent: running it twice is safe. It reports progress for
# every step, and the long converge step streams the ansible-pull output from
# the systemd journal so the terminal shows what is happening.

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

SECONDS=0

log()  { printf '[bootstrap %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
step() { printf '\n[bootstrap %s] === %s ===\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[bootstrap %s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

trap 'fail "bootstrap failed at line $LINENO"' ERR

# --- 0. Sanity checks -------------------------------------------------------

step "0/6 Checking prerequisites"

[ "$(id -u)" -eq 0 ] || fail "must be run as root (sudo scripts/bootstrap.sh)"
log "running as root, OK"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"
log "repository checkout: $REPO_DIR"

[ -f "$SERVICE_SRC" ]    || fail "missing $SERVICE_SRC (run from a checkout of the repository)"
[ -f "$TIMER_SRC" ]      || fail "missing $TIMER_SRC (run from a checkout of the repository)"
[ -f local.yml ]         || fail "missing local.yml (run from a checkout of the repository)"
[ -f requirements.yml ]  || fail "missing requirements.yml (run from a checkout of the repository)"
log "required files present, OK"

# --- 1. Install ansible and git --------------------------------------------

step "1/6 Installing Ansible, Git and the community.general collection"

log "updating the apt package cache (about a minute)"
apt-get update

log "installing ansible + git (a few minutes on a fresh laptop)"
DEBIAN_FRONTEND=noninteractive apt-get install -y ansible git

command -v ansible-pull >/dev/null 2>&1 || fail "ansible-pull not found after installing ansible"
log "ansible-pull available at $(command -v ansible-pull)"

# Ensure the community.general collection is available (needed by the
# flatpak_apps role). Prefer the distro package if it exists; otherwise
# install the pinned version from requirements.yml (compatible with the
# ansible-core shipped by the Mint/Ubuntu base).
if apt-cache show ansible-collection-community-general >/dev/null 2>&1; then
    log "installing community.general from the distro package"
    DEBIAN_FRONTEND=noninteractive apt-get install -y ansible-collection-community-general
else
    # Always enforce the pin (idempotent: skips when already satisfied),
    # even if some other community.general version is already present.
    log "installing pinned collections from requirements.yml"
    ansible-galaxy collection install -r requirements.yml
fi

# --- 2. Create the pull directory -------------------------------------------

step "2/6 Preparing the pull directory"

log "creating $PULL_DIR (where ansible-pull keeps its checkout)"
mkdir -p "$PULL_DIR"

# --- 3. Install systemd units (substituting REPO_URL into the service) ------

step "3/6 Installing the systemd service and timer"

log "installing systemd units (REPO_URL=$REPO_URL)"
# Escape sed replacement metacharacters (& and the | delimiter) in the URL.
REPO_URL_ESCAPED="$(printf '%s' "$REPO_URL" | sed 's/[&|]/\\&/g')"
sed "s|REPO_URL|$REPO_URL_ESCAPED|g" "$SERVICE_SRC" > "$SERVICE_DST"
install -m 0644 "$TIMER_SRC" "$TIMER_DST"
chmod 0644 "$SERVICE_DST"
log "wrote $SERVICE_DST and $TIMER_DST"

# --- 4. Reload systemd ------------------------------------------------------

step "4/6 Reloading systemd"

log "reloading systemd so it picks up the new units"
systemctl daemon-reload
log "systemd reloaded"

# --- 5. Apply the configuration once, immediately ---------------------------
# Start the service (not a second manual ansible-pull) so the converge and
# the timer can never overlap on the same pull directory / apt locks.

step "5/6 Applying the configuration (first converge)"

log "this is the long step: it clones the repo and installs/updates software"
log "live ansible output follows; typically 2-10 minutes on a fresh laptop"
log "you can also follow it from another terminal with:"
log "    journalctl -u ansible-pull.service -f"

converge_ok=1
journal_pid=""

if command -v journalctl >/dev/null 2>&1; then
    # Start the follower before the unit so no output is missed. --output=cat
    # drops the journal's timestamp/unit prefixes and keeps the ansible log
    # readable, which is what a human watching the terminal wants.
    journalctl -u ansible-pull.service -f -n 0 --no-pager --output=cat &
    journal_pid=$!
    sleep 1
else
    log "journalctl not available; waiting for the converge without live output"
fi

# A failure here must NOT prevent the timer from being enabled: otherwise a
# transient network/DNS error on a fresh laptop would leave it with no
# automatic retry at all. The failure is still reported below (exit non-zero).
systemctl start ansible-pull.service || converge_ok=0

if [ -n "$journal_pid" ]; then
    # Give the journal a moment to flush the last lines, then stop the follower.
    sleep 1
    kill "$journal_pid" 2>/dev/null || true
    wait "$journal_pid" 2>/dev/null || true
fi

if [ "$converge_ok" -eq 0 ]; then
    log "WARNING: the converge reported failures (see output above)"
    log "the timer will still be enabled below, so the next run retries automatically"
else
    log "converge finished without failures"
fi

# --- 6. Enable the timer for recurring runs ---------------------------------
# Enabled only after the manual converge attempt, so the first timer tick
# cannot race with it.

step "6/6 Enabling the hourly timer"

log "enabling ansible-pull.timer (runs every hour, 1 min after boot)"
systemctl enable --now ansible-pull.timer

log "scheduled runs:"
systemctl list-timers ansible-pull.timer --no-pager 2>/dev/null || true

if [ "$converge_ok" -eq 0 ]; then
    fail "first ansible-pull converge failed; the timer is enabled and will retry within the hour"
fi

log "SUCCESS: laptop is configured; ansible-pull re-applies this repo every hour"
log "check status: systemctl status ansible-pull.service"
log "check logs:   journalctl -u ansible-pull.service -n 50"
log "total time:   $((SECONDS / 60))m$((SECONDS % 60))s"
