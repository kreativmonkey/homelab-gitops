# ADR 0001: DR overlay is transient only, not the production path

- Status: accepted
- Date: 2026-08-21
- Issue: #734

## Context

`clusters/main/infrastructure.yaml` (Kustomization `infra-main`) pointed
permanently at `./infrastructure/overlays/disaster-recovery`. That overlay
strategic-merges `spec.bootstrap.recovery` (from S3/Barman) onto the running
CNPG clusters `homelab-postgres` and `immich-postgres`, plus `force: true` /
`wait: false`.

The DR overlay is documented as opt-in: its own comment says "Activate by
pointing Flux infra-main to it", and `docs/disaster-recovery/README.md` step 4
says to revert to `../main` after recovery. The wiring was a leftover from a
DR test (commit `18b9d782`) that never got reverted.

## Decision

- Production default for `infra-main.path` is `./infrastructure/overlays/main`.
- The `disaster-recovery` overlay is activated **only transiently** during a
  CNPG S3 recovery, and must be reverted immediately afterward.
- `force: true` is removed from `infra-main`: it forces SSA field overwrite and
  has no justification for steady-state operation (risk of clobbering
  server-side field ownership on CNPG clusters).
- `wait` restored to `true` (safe default; `wait: false` was a DR-specific
  relaxation for slow post-DR ACME DNS-01). DR runs keep `wait: false` via the
  committed spec if needed.

## Consequences

- A pure Spec switch back to `../main` does not touch the running clusters:
  CNPG treats `bootstrap` as immutable after creation, so removing the recovery
  patch has no effect on live DBs.
- Leaving the DR path active is now explicitly forbidden in the overlay comment
  and the runbook, with a pointer to this ADR.

## Validation / Rollback

- After change: `flux reconcile kustomization infra-main -n flux-system`;
  `kubectl get clusters.postgresql.cnpg.io -n cnpg-system` stays healthy.
- Rollback: set `path` back to `./infrastructure/overlays/disaster-recovery`
  only for an actual recovery, then revert.
