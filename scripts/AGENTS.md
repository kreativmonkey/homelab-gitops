# Purpose

Helper scripts: CI validation/audit (`ci/`), monitoring purge tools (`monitoring/`), one-off ops helpers (TrueNAS iSCSI discovery, n8n webhook test).

# Ownership

- Owns: shell scripts invoked by CI pipeline and manual ops.
- CI workflow definitions owned by `.forgejo/workflows/` and `.github/workflows/` (GitHub-only: scheduled scan, upstream-health).

# Local Contracts

- CI validation is split into independent stage scripts: `ci/lib.sh` (shared helpers, sourced not run), `ci/kustomize-validate.sh`, `ci/helm-render.sh`, `ci/server-dry-run.sh` (needs Docker) — plus the pre-existing `ci/offsite-capture-test.sh` (kubectl-stub regression for the Nextcloud capture retry, run by `just validate`), `ci/renovate-audit.sh` and the inline yamllint recipe in `justfile`. `ci/kustomize-validate.sh` also runs `ci/homepage-kubernetes-access.sh` to enforce the cross-resource discovery/RBAC contract and reject annotated Ingress rules without HTTP paths. Wired together as `justfile` recipes (`just validate` = schema-only stages, `just validate-full` = + server-dry-run) and run as separate parallel jobs in `.forgejo/workflows/pr-validation.yaml` / `.github/workflows/pr-validation.yaml`.
- `ci/upstream-health.sh` + `ci/upstream-health.py` (stdlib only) + `ci/upstream-health.json` (sources/eol/frozen/ignore): weekly dead/moved/EOL-upstream check, run by `.github/workflows/upstream-health.yaml` via `just upstream-health --publish` in `nix develop .#upstream`; writes the `upstream-health` GitHub issue. Details `docs/renovate.md` § Upstream Health.
- Version pins in scripts use `NAME_VERSION="x" # renovate: datasource=… depName=…` (custom manager in `renovate.json`).
- Scripts must be POSIX/bash, idempotent where possible, and safe to run standalone.
- Destructive scripts (`monitoring/purge-*`) must state scope and require explicit target.

# Work Guidance

- Keep scripts self-documenting with a header comment describing purpose + usage.

# Verification

- Run the script against a dry-run/non-prod target before wiring into CI.

# Child DOX Index

No child AGENTS.md.
