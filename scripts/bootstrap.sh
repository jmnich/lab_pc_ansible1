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

# Output is deliberately terse: one line per step, saying what happened rather
# than restating what the next command will do. Failures stay loud.
log()  { printf '  %s\n' "$*"; }
step() { printf '%-42s' "$*"; }
done_() { printf 'ok\n'; }
fail() { printf 'FAILED\n' >&2; printf '  %s\n' "$*" >&2; exit 1; }

trap 'fail "bootstrap failed at line $LINENO"' ERR

# --- 0. Sanity checks -------------------------------------------------------

step "Checking prerequisites"
[ "$(id -u)" -eq 0 ] || fail "must be run as root (sudo scripts/bootstrap.sh)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

[ -f "$SERVICE_SRC" ]    || fail "missing $SERVICE_SRC (run from a checkout of the repository)"
[ -f "$TIMER_SRC" ]      || fail "missing $TIMER_SRC (run from a checkout of the repository)"
[ -f local.yml ]         || fail "missing local.yml (run from a checkout of the repository)"
[ -f requirements.yml ]  || fail "missing requirements.yml (run from a checkout of the repository)"
done_

# --- 1. Install ansible and git --------------------------------------------

step "Installing Ansible + Git"
apt-get update >/dev/null 2>&1 || fail "apt-get update failed (check the network)"
DEBIAN_FRONTEND=noninteractive apt-get install -y ansible git >/dev/null 2>&1 \
    || fail "could not install ansible and git"

command -v ansible-pull >/dev/null 2>&1 || fail "ansible-pull not found after installing ansible"

# Ensure the community.general collection is available (needed by the
# flatpak_apps role). Prefer the distro package if it exists; otherwise
# install the pinned version from requirements.yml (compatible with the
# ansible-core shipped by the Mint/Ubuntu base).
if apt-cache show ansible-collection-community-general >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y ansible-collection-community-general >/dev/null 2>&1 \
        || fail "could not install ansible-collection-community-general"
else
    # Always enforce the pin (idempotent: skips when already satisfied),
    # even if some other community.general version is already present.
    ansible-galaxy collection install -r requirements.yml >/dev/null 2>&1 \
        || fail "could not install the pinned collections from requirements.yml"
fi
done_

# --- 2. Create the pull directory -------------------------------------------

step "Preparing the pull directory"
mkdir -p "$PULL_DIR"
done_

# --- 3. Install systemd units (substituting REPO_URL into the service) ------

step "Installing systemd units"
# Escape sed replacement metacharacters (& and the | delimiter) in the URL.
REPO_URL_ESCAPED="$(printf '%s' "$REPO_URL" | sed 's/[&|]/\\&/g')"
sed "s|REPO_URL|$REPO_URL_ESCAPED|g" "$SERVICE_SRC" > "$SERVICE_DST"
install -m 0644 "$TIMER_SRC" "$TIMER_DST"
chmod 0644 "$SERVICE_DST"
done_

# --- 4. Reload systemd ------------------------------------------------------

step "Reloading systemd"
systemctl daemon-reload
done_

# --- 5. Apply the configuration once, immediately ---------------------------
# Start the service (not a second manual ansible-pull) so the converge and
# the timer can never overlap on the same pull directory / apt locks.

step "Applying configuration (2-10 min)"
printf '\n'

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
    log "journalctl not available; waiting without live output"
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

printf '\n'
if [ "$converge_ok" -eq 0 ]; then
    log "converge reported failures; the timer will retry within the hour"
else
    log "converge finished without failures"
fi

# --- 6. Enable the timer for recurring runs ---------------------------------
# Enabled only after the manual converge attempt, so the first timer tick
# cannot race with it.

step "Enabling the hourly timer"
systemctl enable --now ansible-pull.timer
done_

if [ "$converge_ok" -eq 0 ]; then
    fail "first converge failed; the timer is enabled and will retry within the hour"
fi

printf '\nDone in %dm%02ds. Re-applies every hour.\n' "$((SECONDS / 60))" "$((SECONDS % 60))"
printf 'Check status: sudo lab_update --status\n'
