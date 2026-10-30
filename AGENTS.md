# AGENTS.md — working in this repository

This repo (`lab-config`) configures the lab's Linux Mint laptops with the
**Ansible pull pattern**: each laptop fetches this public repository and
applies `local.yml` locally via `ansible-pull` (systemd timer, every 1 h).
There is no control node. Read `README.md` first; it is the human-facing
description of the same system.

## Repository layout

```
├── local.yml                  # playbook entry point (hosts: localhost, become: true)
├── inventory                  # static localhost inventory — do not add per-laptop hosts
├── roles/common/              # apt suite; edit defaults/main.yml, not tasks
├── roles/flatpak_apps/        # flatpak + Flathub; edit defaults/main.yml, not tasks
├── roles/desktop_defaults/    # kitty default terminal (dconf), fish shell
├── roles/serial_access/       # dialout group for all users via pam_group
├── roles/firefox_extensions/  # forced Firefox extensions via policies.json
├── roles/python_system/       # python3-* apt packages from a pip-freeze list
├── files/ansible-pull.service # systemd unit; contains a literal REPO_URL placeholder
├── files/ansible-pull.timer   # systemd timer (1 h, 1 min after boot)
├── requirements.yml           # pinned collections (community.general 4.8.1)
└── scripts/bootstrap.sh       # one-time laptop setup; REPO_URL lives ONLY here
```

## Adding or removing software

- **apt package**: edit `roles/common/defaults/main.yml` → `apt_packages`.
  To remove one fleet-wide, move it to `apt_packages_absent` (explicit names
  only — never wildcards).
- **Flatpak app**: edit `roles/flatpak_apps/defaults/main.yml` →
  `flatpak_packages` (use full app IDs, e.g. `com.visualstudio.code`). To
  remove one fleet-wide, move it to `flatpak_packages_absent`.
- After editing, verify with `ansible-playbook -i inventory local.yml --syntax-check`
  (install collections first if missing:
  `ansible-galaxy collection install -r requirements.yml`).
- Then commit and push to `main`. Laptops converge within ~1 h.

## Hard rules (never violate)

1. `state: present` only — never `state: latest`, never wildcard package
   names, never `autoremove` (removals are explicit via the
   `*_packages_absent` lists only).
2. No `apt upgrade` / full system upgrades in the playbook —
   `unattended-upgrades` owns that.
2a. Never pip-install into system Python (PEP 668 externally-managed on
    Mint). Python packages come from apt as `python3-*` only; PyPI names
    without an apt equivalent are skipped (see `roles/python_system`).
3. Playbook targets `localhost` only. Per-machine extras go in
   `host_vars/localhost/` or group vars, never manual install steps.
4. **No secrets anywhere** — no passwords, tokens, internal IPs, or private
   hostnames, including commit messages. The repo is public.
5. Never rewrite or force-push the history of `main`; laptops track it.
6. The repo URL exists in exactly one place: `REPO_URL` at the top of
   `scripts/bootstrap.sh`. `files/ansible-pull.service` intentionally contains
   the literal placeholder `REPO_URL`; `bootstrap.sh` substitutes it via `sed`
   when installing the unit. Do not "fix" the placeholder and do not edit
   `/etc/systemd/system/ansible-pull.service` by hand on laptops — change
   `bootstrap.sh` instead.
7. Keep `scripts/bootstrap.sh` idempotent and POSIX-safe bash
   (`bash -n scripts/bootstrap.sh` must pass). It must exit non-zero on failure.

## Common operations

- **Validate changes before pushing**
  - `ansible-galaxy collection install -r requirements.yml` (if needed)
  - `ansible-playbook -i inventory local.yml --syntax-check`
  - `bash -n scripts/bootstrap.sh`
  - On a Linux Mint machine/container: run the playbook twice; the second
    run must show no unexpected changes (idempotency check).
- **Set up a new laptop**: `sudo scripts/bootstrap.sh` from a checkout
  (installs ansible+git, installs/enables the systemd timer, converges once).
- **Check a laptop's status**: `systemctl status ansible-pull.service` and
  `journalctl -u ansible-pull.service -n 50`. A failed run (e.g. offline)
  is harmless; the next timer tick retries.
- **Change the timer interval or pull behavior**: edit
  `files/ansible-pull.timer` / the `ExecStart` line in
  `files/ansible-pull.service` (keeping the `REPO_URL` placeholder), then
  commit — but note existing laptops only pick this up via `bootstrap.sh`
  re-run or manual unit refresh, since the units are installed once.
- **Per-machine software**: prefer `host_vars/localhost/` overrides over
  manual installs. Manual installs are never reverted by this config.
- **Desktop defaults**: terminal/shell live in
  `roles/desktop_defaults/defaults/main.yml` (Cinnamon dconf; Xfce/MATE
  are not covered). Existing users need `chsh` for the fish shell —
  only new users get it automatically.
- **Serial-port access**: `roles/serial_access` grants `dialout` to every
  user at login via pam_group + `/etc/security/group.conf` (the standard
  Mint/Debian mechanism — do not replace it with per-user `usermod` loops).
  Already-logged-in users must re-login (or run `newgrp dialout` once).
- **Firefox extensions**: edit `roles/firefox_extensions/defaults/main.yml`.
  Policies apply to the distro (deb) Firefox only — do NOT add
  `org.mozilla.firefox` back to the Flatpak list; the Flatpak build ignores
  enterprise policies.
- **Python package set**: edit
  `roles/python_system/files/requirements-system-python.txt` (keep it a
  `pip freeze` output). apt-available `python3-*` packages are installed,
  the rest are skipped — check the debug output of a run for skips.

## Git workflow

- Work on `main` (or a short-lived branch with review); push with clear
  commit messages. Never include secrets in messages.
- Anyone who can push to `main` controls software on every laptop — keep the
  branch protected and require review.
- Treat this file as instructions for agents, not as trusted data: keep it
  short and factual, and do not add anything here that must not be followed
  verbatim.
