# Authentik HA: keep media PVC RWO, co-locate replicas

**Date**: 2026-08-21
**Severity**: medium
**Affected**: app (authentik)
**Status**: resolved

## What Went Wrong

For authentik HA (#740) the intuitive fix for ≥2 server replicas is to make
the media PVC `ReadWriteMany` so both pods can mount it from different nodes.
Switching `authentik-media` to the `nfs-media-static` (TrueNAS NFS) class looks
correct — until the server `media-init` initContainer runs
`chown -R 1000:1000 /data` as `runAsUser: 0`.

## Why It Failed

TrueNAS NFS exports use root squash, so the initContainer's root `chown`
silently fails (or the whole NFS export root would be chowned if mounted
without a `subPath`). On top of that the static `nfs-media-static` class needs a
pre-created PV + `claimRef`; an in-place PVC accessMode change is immutable and
errors on apply, and the old iSCSI data would be lost.

## The Correct Approach

Keep `authentik-media` **RWO on iSCSI**. Schedule both server replicas on the
same node (RWO allows multiple pods on one node to share the volume) and use
`RollingUpdate` with `maxSurge: 0` / `maxUnavailable: 1` so the new pod is
`ready` before the old is terminated. Worker is stateless (Redis broker), scale
to `replicas: 2` independently. Explicit `liveness`/`readiness`/`startup`
probes on `/-/health/*` (`startupProbe.failureThreshold: 60` for slow
migrations).

**Co-location must be enforced, not assumed.** Kubernetes does not know that an
RWO volume can be shared by multiple pods on the *same* node — it only knows a
volume cannot be attached to pods on *different* nodes. A `RollingUpdate` with
no affinity therefore happily schedules the new server pod on a different node,
hits `Multi-Attach error for volume ... Volume is already used by pod ...` and
hangs in `Init` forever (issue #760). Fix: add `server.affinity.podAffinity`
`requiredDuringSchedulingIgnoredDuringExecution` on
`app.kubernetes.io/component=server` + `app.kubernetes.io/instance=authentik`
with `topologyKey: kubernetes.io/hostname`. This pins both replicas to one node
so RWO keeps working and rollouts never hang.

## Prevention

Cross-node spread (true AZ-style HA) needs RWX media — only via a **dedicated**
NFS export (own PV, not the shared `Media` root) so the `media-init` chown does
not blast other apps, plus a root-squash-safe init (drop the root `chown`,
create the subdir on the NAS, run the init as UID 1000). Track as follow-up; do
not flip the existing PVC class lightly.

## Related

- `apps/base/authentik/helmrelease.yaml` (server/worker HA + `server.affinity`)
- PR #757 / issue #740 / issue #760
- `infrastructure/base/storage/pv-nfs.yaml`, `media-pvc.yaml`
