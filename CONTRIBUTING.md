# Contributing

## Setup
- Clone the repo and ensure Bash, Docker, and `shellcheck` are available locally.
- Scripts expect Debian/Ubuntu targets; test changes on a fresh Debian-like environment.

## Testing
- Lint: `shellcheck debian-server.sh`.
- Container smoke test (skips snap and Docker installs):  
  `docker build --build-arg SKIP_SNAP=1 --build-arg SKIP_DOCKER=1 --build-arg NEW_USER=tester -t ignition-scripts:test .`
- Verify user creation: `docker run --rm ignition-scripts:test getent passwd tester`.
- On real hosts, omit `SKIP_SNAP`/`SKIP_DOCKER` so snap and Docker install as expected.

## Script guidelines
- Keep `set -eu` at the top; prefer `apt-get` with explicit flags.
- Quote variables, use arrays for package lists, and guard optional steps (snap/Docker).
- Avoid embedding secrets; use env vars for passwords (e.g., `NEW_USER_PASSWORD`) only when needed.

## Pull requests
- Describe the change, test commands, and environments used.
- Note any external URLs added/updated (themes, installers) and why.
- Use present-tense, imperative commit messages (e.g., "Add container smoke test"). 
