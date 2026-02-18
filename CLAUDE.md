# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Ignition Scripts** — a single Bash script (`debian-server.sh`) that bootstraps a fresh Debian/Ubuntu VPS with nginx, Docker, Zsh (Oh My Zsh), certbot, and a configured non-root user.

Installation one-liner:
```shell
NEW_USER=admin bash -c "$(wget https://raw.githubusercontent.com/aris997/scripts/refs/heads/main/debian-server.sh -O -)"
```

## Commands

**Lint:**
```shell
shellcheck debian-server.sh
```

**Syntax check only (no shellcheck needed):**
```shell
bash -n debian-server.sh
```

**Container smoke test (skips snap/Docker installs):**
```shell
docker build --build-arg SKIP_SNAP=1 --build-arg SKIP_DOCKER=1 --build-arg NEW_USER=tester -t ignition-scripts:test .
docker run --rm ignition-scripts:test getent passwd tester
```

**Trace execution for debugging:**
```shell
bash -x debian-server.sh
```

**CI** runs shellcheck + Docker build + user-creation verification on every push/PR (`.github/workflows/test.yml`).

## Architecture

The repo is intentionally flat — one script at the root, plus a `Dockerfile` for container-based testing. New scripts should also live at the root with descriptive names (e.g., `task-name.sh`).

`debian-server.sh` runs in phases, top to bottom:
1. **Base packages** — apt update/upgrade, installs nginx, git, htop, vim, zsh, ca-certificates, curl (+ snapd unless `SKIP_SNAP=1`)
2. **User creation** — creates `$NEW_USER`, sets optional password, adds to sudo, copies root's `authorized_keys`
3. **Certbot** — via snap (default) or apt when `SKIP_SNAP=1`
4. **Docker** — removes conflicting packages, adds Docker's apt repo, installs Docker CE + plugins, adds user to `docker` group (skipped when `SKIP_DOCKER=1`)
5. **Oh My Zsh** — installs Oh My Zsh, fetches a custom theme and `.zshrc` from the `aris997/dotfiles` repo, sets zsh as the user's shell

**Environment variables (all optional):**
| Variable | Default | Purpose |
|---|---|---|
| `NEW_USER` | `admin` | Username to create |
| `NEW_USER_PASSWORD` | _(empty)_ | Password for the user |
| `SKIP_SNAP` | `0` | Set to `1` to skip snap/certbot-via-snap |
| `SKIP_DOCKER` | `0` | Set to `1` to skip Docker installation |

`Dockerfile` defaults to `SKIP_SNAP=1 SKIP_DOCKER=1` and targets `debian:13`.

## Coding Style

- Scripts start with `#!/bin/bash` and `set -eu`.
- 4-space indentation; no tabs.
- Config variables in `ALL_CAPS`; use arrays for package lists.
- Guard optional steps with idempotency checks (e.g., `command -v docker`, `id -u "$NEW_USER"`).
- Prefer long-form flags (`--classic`, `--no-install-recommends`) for clarity.
- Remote assets fetched via HTTPS `wget`; keep URLs near the top for easy updates.
