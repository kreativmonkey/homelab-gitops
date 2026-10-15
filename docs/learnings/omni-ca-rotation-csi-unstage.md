# Kubernetes CA Rotation Unstaged iSCSI Volumes of Running Pods

**Date**: 2026-10-15
**Severity**: high
**Affected**: cluster-wide (all iSCSI workloads on talos-cp1 and talos-cp3)
**Status**: resolved

## What Went Wrong

`omnictl cluster secret rotate kubernetes-ca` completed cleanly, and a sweep
for `x509` errors plus targeted restarts left the cluster "green". About 40
minutes later Renovate failed on every repository: Forgejo answered
`info/refs` with 200 but an empty body, and its log showed
`fork/exec /usr/bin/git: input/output error` and
`Open Repository … no such file or directory`.

## Why It Failed

- During the rotation the kubelet restarted with new certificates. On cp1 and
  cp3 it called `NodeUnpublishVolume` + `NodeUnstageVolume` for 18 iSCSI
  volumes that were **still in use by running pods** (19:21 UTC; cp2 unaffected).
- democratic-csi logged out the iSCSI sessions: `device offline error`,
  `Buffer I/O error`, `Aborting journal on device sdX-8`.
- The pods kept running on dead mounts — no restart, no event, no x509 line.
  Readiness probes that do not touch the volume stayed green.
- Data written in the ~2 h until the fix was lost (Grafana, VictoriaMetrics,
  VictoriaLogs, TimescaleDB/KNX, Forgejo pushes would have failed).

The trigger for the kubelet's unstage is not proven; the timing matches the
rotation's kubelet restart exactly on both nodes.

## The Correct Approach

1. Read `NodeUnstageVolume` calls from the democratic-csi node logs for the
   rotation window → PV → PVC → pods (`docs/runbooks/ca-rotation.md`).
2. Delete those pods (RWO: no rolling restart), databases first, in small
   batches.
3. Verify: `EXT4-fs … recovery complete`, `mounted … r/w`, `dumpe2fs -h`
   `Filesystem state: clean` with no `FS Error count`, app logs clean.
   On 2026-10-15 all filesystems came back clean; no `e2fsck` needed.

## Prevention

- Treat a Kubernetes CA rotation like a node drain for stateful workloads:
  check CSI unstage calls right after it, before declaring success.
- A "no x509 errors" sweep is not a health check for volumes.
- Diagnosis trick: `git ls-remote` with `GIT_CURL_VERBOSE=1` showed a 200 on
  `info/refs` followed by `Could not read from remote repository` — the
  server-side git process failed, so look at the Forgejo pod, not the network.

## Related

- [docs/runbooks/ca-rotation.md](../runbooks/ca-rotation.md)
- [nextcloud-iscsi-emergency-readonly.md](nextcloud-iscsi-emergency-readonly.md)
