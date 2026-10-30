# lab-config

Configuration management for the lab's Linux Mint laptops, using the
Ansible pull pattern: every laptop fetches this repository on its own and
applies it locally. There is no central control node, and laptops do not
need to be online at the same time.

The repository URL is configured in exactly one place: the `REPO_URL`
variable at the top of `scripts/bootstrap.sh`.

## What this repository manages

- The base apt software suite (see `roles/common/defaults/main.yml`)
- A curated set of Flatpak apps (see `roles/flatpak_apps/defaults/main.yml`)
- The Flathub remote, system-wide
- The systemd timer that runs `ansible-pull` every hour (1 min after boot)
- Automatic security upgrades via `unattended-upgrades` (installed and
  enabled by `roles/common`)

What this repository deliberately does NOT manage:

- Full system package upgrades (only unattended security upgrades)
- Anything installed manually on a laptop. Manually installed software is
  never touched by this configuration.

## How to change the software suite

1. Edit the package list in `roles/common/defaults/main.yml`
   (apt packages) or `roles/flatpak_apps/defaults/main.yml` (Flatpak apps).
2. To remove an app fleet-wide, move it from the install list to
   `apt_packages_absent` (apt) or `flatpak_packages_absent` (Flatpak).
3. Commit and push to `main`.

Every laptop that is online applies the change within about one hour.
A laptop that was offline applies it on its next run after booting.
Never rewrite the history of `main`; the laptops track this branch.

## Setting up a new laptop

Run once, with sudo, from a checkout of this repository:

    sudo scripts/bootstrap.sh

This installs Ansible and Git, installs the systemd service and timer,
and applies the configuration immediately. Nothing else is required.

## How to check status on a laptop

    systemctl status ansible-pull.service
    journalctl -u ansible-pull.service -n 50

A failed run (for example, while the laptop was offline) is harmless;
the next timer tick retries automatically.

## How to install something on just one laptop

Prefer making it permanent and reproducible: add a host variable override
or a group variable instead of installing manually. Manual installation
also works and will not be reverted, but it will not survive a laptop
reinstallation and is invisible to everyone else.

## Security notes

- This repository is public. Do not commit secrets, tokens, internal
  addresses, or private hostnames.
- Anyone who can push to `main` controls the software on every laptop.
  Keep the branch protected and require review for changes.
- The repository URL is configured in `scripts/bootstrap.sh` (variable
  `REPO_URL`), which is the only place it should be edited.
