# PSS Restricted: Phase 1 for #746

This GitOps-only phase deliberately keeps `enforce=baseline`. It enables
`audit=restricted` and `warn=restricted` only for four narrowly scoped app
namespaces, while applying explicit Restricted controls where the current
workload or chart supports them.

## Included namespaces

| Namespace | Phase 1 change | Gate before a separate `enforce=restricted` PR |
|---|---|---|
| `audiobookshelf` | Raw Deployment hardened; audit/warn set to Restricted | Reconcile, recreate one Pod, `/healthcheck`, login, and persistent write/read checks for `/config` and `/metadata` |
| `kite` | Chart values set pod/container controls; audit/warn set to Restricted | Reconcile, UI and SQLite write check, recreate one Pod, inspect events |
| `kavita` | Raw Deployment hardened; audit/warn set to Restricted | Reconcile, `/api/health`, login/library scan, and persistent write/read check for `/kavita/config` |
| `sterling-pdf` | Chart values plus a version-specific post-renderer patch; audit/warn set to Restricted | Reconcile, PDF conversion, persistent configuration write/read check, recreate one Pod, inspect events |

`jellyfin` and `renovate` receive explicit controls in this change but retain
current PSA labels. They require their own restart and persistent-storage gates
before any PSA label change.

## Excluded scope

No namespace is set to `enforce=restricted` in this PR. Privileged or mixed
boundaries remain unchanged, including `netbird`, `watchyourlan`,
`democratic-csi`, `ingress-nginx`, `monitoring`, `cnpg-system`, and the Forgejo
runner boundary. A running Pod is not proof of future admission compliance.

## Required post-merge sequence

1. Let Flux reconcile the merged revision.
2. Per included namespace, inspect generated Pod specs, Restricted warnings,
   ReplicaSet/Job events, and readiness.
3. Recreate exactly one application Pod only after normal checks are healthy.
4. Perform the listed application and persistent storage smoke checks.
5. Record results. Only a namespace with no relevant warnings and successful
   gates can receive a separate, one-namespace `enforce=restricted` PR.

Rollback remains GitOps-only: revert the affected commit, let Flux reconcile,
and repeat readiness, smoke, and event checks. Do not patch namespace labels or
roll back workloads directly in the cluster.
