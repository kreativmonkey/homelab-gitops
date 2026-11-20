# Purpose

Helper scripts: CI validation/audit (`ci/`), monitoring purge tools (`monitoring/`), one-off ops helpers (TrueNAS iSCSI discovery, n8n webhook test).

# Ownership

- Owns: shell scripts invoked by CI pipeline and manual ops.
- CI workflow definitions owned by `.forgejo/workflows/` and `.github/workflows/` (GitHub-only: scheduled scan, upstream-health).

# Local Contracts

- CI validation is split into independent stage scripts: `ci/lib.sh` (shared helpers, sourced not run), `ci/kustomize-validate.sh`, `ci/helm-render.sh`, `ci/server-dry-run.sh` (needs Docker) — plus the pre-existing `ci/offsite-capture-test.sh` (stub regressions for offsite capture retries and Storage Box quota checks, run by `just validate`), `ci/renovate-audit.sh` and the inline yamllint recipe in `justfile`. `ci/kustomize-validate.sh` also runs `ci/homepage-kubernetes-access.sh` to enforce the cross-resource discovery/RBAC contract and reject annotated Ingress rules without HTTP paths. Wired together as `justfile` recipes (`just validate` = schema-only stages, `just validate-full` = + server-dry-run) and run as separate parallel jobs in `.forgejo/workflows/pr-validation.yaml` / `.github/workflows/pr-validation.yaml`.
- `ci/upstream-health.sh` + `ci/upstream-health.py` (stdlib only) + `ci/upstream-health.json` (sources/eol/frozen/ignore): weekly dead/moved/EOL-upstream check, run by `.github/workflows/upstream-health.yaml` via `just upstream-health --publish` in `nix develop .#upstream`; writes the `upstream-health` GitHub issue. Details `docs/renovate.md` § Upstream Health.
- Version pins in shell/Python scripts use `NAME_VERSION="x" # renovate: datasource=… depName=…` (spaces around `=` allowed; optional `registryUrl=…` for Helm). The custom manager in `renovate.json` covers `.sh` and `.py`. Reuse existing version owners: `eso-spike.py` reads CNPG chart version/image tag from its HelmRelease; ESO has its own Helm marker.
- Shell scripts must be POSIX/bash; Python helpers use the standard library. Scripts are idempotent where possible and safe to run standalone.
- Destructive scripts (`monitoring/purge-*`) must state scope and require explicit target.
- `eso-spike.py` (`just eso-spike`) creates and removes its own local Kind cluster and kubeconfig; tests ESO lifecycle, per-namespace source allowlists/shared DB/OIDC readers, Outline's 64-hex key format, and CNPG password rotation with synthetic credentials. Never point it at an existing cluster or import production secrets. Flux prune, Velero restore and production Cilium are separate checks.

# Work Guidance

- Keep scripts self-documenting with a header comment describing purpose + usage.

# Verification

- Run the script against a dry-run/non-prod target before wiring into CI.
- `nix develop -c just eso-spike` requires a working Docker/Podman runtime; rootless Podman: `KIND_EXPERIMENTAL_PROVIDER=podman systemd-run --user --scope -p Delegate=yes nix develop -c just eso-spike`. Opt-in integration spike, not part of `just validate`.
- `nix develop -c python3 scripts/ci/cert-manager-ttl-migration-test.py` executes the inline media ACME TTL migration Job with mocked HTTPS; covers value-preserving TTL update, no-op, unexpected TTL refusal, bounded polling, and sanitized failures. Requires dev-shell `yq`; never contacts Hetzner.

# Child DOX Index

No child AGENTS.md.
