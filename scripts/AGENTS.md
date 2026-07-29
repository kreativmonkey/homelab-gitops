# Purpose

Helper scripts: CI validation/audit (`ci/`), monitoring purge tools (`monitoring/`), one-off ops helpers (TrueNAS iSCSI discovery, n8n webhook test).

# Ownership

- Owns: shell scripts invoked by CI pipeline and manual ops.
- CI workflow definitions owned by `.forgejo/workflows/`.

# Local Contracts

- CI validation is split into independent stage scripts: `ci/lib.sh` (shared helpers, sourced not run), `ci/kustomize-validate.sh`, `ci/helm-render.sh`, `ci/server-dry-run.sh` (needs Docker) — plus the pre-existing `ci/renovate-audit.sh` and the inline yamllint recipe in `justfile`. Wired together as `justfile` recipes (`just validate` = schema-only stages, `just validate-full` = + server-dry-run) and run as separate parallel jobs in `.forgejo/workflows/pr-validation.yaml` / `.github/workflows/pr-validation.yaml`.
- Scripts must be POSIX/bash, idempotent where possible, and safe to run standalone.
- Destructive scripts (`monitoring/purge-*`) must state scope and require explicit target.

# Work Guidance

- Keep scripts self-documenting with a header comment describing purpose + usage.

# Verification

- Run the script against a dry-run/non-prod target before wiring into CI.

# Child DOX Index

No child AGENTS.md.
