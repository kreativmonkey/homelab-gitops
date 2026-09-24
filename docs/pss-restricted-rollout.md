# PSS Restricted: Phase 1 for #746

This GitOps-only phase deliberately keeps `enforce=baseline`. It enables
`audit=restricted` and `warn=restricted` only for a narrowly scoped set of app
namespaces, while applying explicit Restricted controls where the current
workload or chart supports them.

Landed 2026-09-23 20:11 UTC (`8e74e6e0`, #982). Four workloads rolled out
cleanly; two regressed and were fixed/reverted on 2026-09-24 (this change,
`fix/pss-phase1-regressions`) — see "Outcome" below.

## Included namespaces

| Namespace | Phase 1 change | Gate before a separate `enforce=restricted` PR |
|---|---|---|
| `audiobookshelf` | Raw Deployment hardened; audit/warn set to Restricted | Reconcile, recreate one Pod, `/healthcheck`, login, and persistent write/read checks for `/config` and `/metadata` |
| `kite` | Chart values set pod/container controls; audit/warn set to Restricted | Reconcile, UI and SQLite write check, recreate one Pod, inspect events |
| `kavita` | Raw Deployment hardened; audit/warn set to Restricted | Reconcile, `/api/health`, login/library scan, and persistent write/read check for `/kavita/config` |
| `sterling-pdf` | ~~Chart values plus a version-specific post-renderer patch; audit/warn set to Restricted~~ Reverted 2026-09-24, see below | n/a — blocked |

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

## Outcome (2026-09-24)

- **audiobookshelf, kavita, kite**: rolled out 2026-09-23 20:14 UTC, pods
  healthy. Gates from the table above are still outstanding — status
  unchanged from the original plan.
- **jellyfin**: hardened and healthy, same as planned.
- **sterling-pdf**: **blocked, reverted.** The forced `runAsUser: 1000` /
  `runAsNonRoot: true` (plus dropped capabilities) made the Deployment
  unschedulable: the `2.14.3` entrypoint requires root to `chown`/`chmod`
  `/tmp/stirling-pdf` and to symlink `diagnostics` into `/usr/local/bin`.
  Reproduced in-cluster on 2026-09-24 with exactly that securityContext —
  container exits 1 with `Permission denied` / `Operation not permitted`.
  New pods never became ready, the Deployment hit
  `ProgressDeadlineExceeded`, four Helm upgrades failed and auto-rolled back,
  and the HelmRelease went `Stalled=True RetriesExceeded` (critical alert
  `FluxReconcileFailing`, firing since 2026-09-23 21:11 UTC). The old pod
  (uid 0) kept serving throughout. Fix: reverted the securityContext
  hardening and the post-renderer patch in
  `apps/base/sterling-pdf/helmrelease.yaml`, and reverted
  `apps/base/sterling-pdf/namespace.yaml` audit/warn from `restricted` back
  to `baseline` (the workload provably cannot reach Restricted right now, so
  audit/warn at restricted would only produce permanent noise). Unblocks
  when upstream Stirling-PDF ships a rootless entrypoint — re-attempt then.
- **renovate**: hardening retained, but corrected. The commit forced
  `runAsUser`/`runAsGroup`/`fsGroup: 1000`, but the renovate image runs
  natively as `uid=12021` (`ubuntu`), and the existing 20Gi `renovate-cache`
  PVC (all ~102k entries) is owned by that uid — every run since
  2026-09-23 20:06 UTC failed with `EACCES` on
  `/tmp/renovate/cache/__renovate-private-cache`, silently, because the
  `renovate` CronJob was not registered with the job watchdog. Fixed by
  changing uid/gid 1000 → 12021 in both securityContext blocks in
  `apps/base/renovate/helmrelease.yaml`, and by registering the CronJob with
  the watchdog (`homelab.f4mily.net/watchdog: "true"`,
  `max-age-hours: "9"`). Also registered `nextcloud/nextcloud-cron`, the
  other previously-unmonitored CronJob (`max-age-hours: "1"`, 5-minute
  schedule), found during the same investigation.

### Lessons

- Before forcing `runAsUser` on a workload, verify **both** the image's
  built-in uid (check the entrypoint/Dockerfile, or reproduce with the
  intended securityContext before merging) **and** the ownership of any
  persistent volume it already wrote to. Guessing `1000` is not free — it
  silently breaks anything that isn't already running as that uid.
