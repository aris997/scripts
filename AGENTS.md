# Repository Guidelines

## Project Structure & Module Organization
- Core automation lives in `debian-server.sh`; it bootstraps a Debian server with nginx, Docker, Zsh, and user setup.
- Documentation: `README.md` for quick install snippet; `LICENSE` for distribution terms.
- No nested modules or assets; keep additional scripts at the repo root with clear names (e.g., `task-name.sh`).

## Build, Test, and Development Commands
- Run the installer locally: `bash debian-server.sh` (assumes Debian/Ubuntu with sudo).
- Remote one-liner (mirrors README): `sh -c "$(wget https://raw.githubusercontent.com/aris997/scripts/refs/heads/main/debian-server.sh -O -)"`.
- Dry-run safety check: `bash -n debian-server.sh` for syntax, `shellcheck debian-server.sh` for linting (install shellcheck first).

## Coding Style & Naming Conventions
- Shell: Bash with `set -eu` for fail-fast; keep that at the top of new scripts.
- Indent with 4 spaces for blocks; avoid tabs. Prefer long-form flags (`--classic`, `--get-selections`) for clarity.
- Variables in `ALL_CAPS` for config (e.g., `NEW_USER`); commands lowercase. Use descriptive function names if you add functions.
- Fetch remote assets via HTTPS `wget` with explicit paths; keep URLs centralized near the top for easy updates.

## Testing Guidelines
- Target environment: fresh Debian/Ubuntu VPS. Test end-to-end on a throwaway instance before merging.
- Validate provisioning steps incrementally: rerun sections with `bash -x debian-server.sh` to trace.
- Add idempotency notes or guards (e.g., `command -v docker`) when extending.

## Commit & Pull Request Guidelines
- Commit messages: use present-tense, imperative summaries (e.g., "Add docker install guard").
- PRs: include a short description of changes, test notes (commands and outcomes), and any environment assumptions (Debian version, privileges).
- If adding remote downloads or user creation steps, link the source URLs and note required permissions.

## Security & Configuration Tips
- Do not embed secrets; use authorized_keys or environment variables loaded at runtime.
- Review external URLs for authenticity before updating. Pin versions where feasible (e.g., Docker repos, theme files).
- Keep file permissions explicit when creating keys or config directories; prefer `install -m` over implicit defaults.
