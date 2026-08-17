# Velero backup issues

## Symptom

`VeleroMetricsAbsent`, `VeleroBackupFailures`, `VeleroBackupNeverSucceeded`,
or `VeleroBackupStale`.

## Checks

```bash
kubectl get backup,backupstoragelocation -n velero
kubectl get daemonset,podvolumebackup -n velero
kubectl logs -n velero deploy/velero --tail=100
kubectl logs -n velero daemonset/node-agent --all-containers --tail=100
velero backup get
```

`PartiallyFailed` is a failed reliability outcome. Inspect its errors even when
`velero_backup_failure_total` stays at zero:

```bash
velero backup describe <backup> --details
kubectl get podvolumebackup -n velero -l velero.io/backup-name=<backup>
```

## Remediation

- Confirm `velero-credentials` secret and BSL phase `Available`
- Confirm `daemonset/node-agent` has one Ready pod per schedulable node
- Confirm each filesystem backup creates and completes `PodVolumeBackup` objects
- Re-run failed schedule: `velero backup create --from-schedule <schedule>`
- Prove recovery with one `Completed` backup and a test restore; controller
  `Ready` status alone does not prove volume data was captured

## Hanging PodVolumeBackups (zombie PVBs)

### Symptom

All backups sit at `PartiallyFailed` with ~50 errors. The errors all carry
the same timestamp, exactly 4h after backup start
(`itemOperationTimeout: 4h`). Typical message:

```
Error backing up item: failed to list node-agent pods: client rate limiter
Wait returned an error: context deadline exceeded
```

### Cause

A `PodVolumeBackup` (PVB) is stuck permanently in phase `Prepared` or
`InProgress` because a node-agent restart (DaemonSet rollout) orphaned the
running kopia operation. The CR is never recognized as dead. Velero
processes ItemBlocks per pod synchronously and waits on the PVB until the
global timeout aborts everything that follows all at once. Result: almost no
PVC data ends up in the backup, even though the backup only looks "partially"
failed.

### Detect

```bash
kubectl get podvolumebackups.velero.io -n velero \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,NODE:.spec.node,START:.status.startTimestamp' \
  | grep -v Completed
```

Anything that stays in `Prepared`/`InProgress` longer than the backup runtime
is suspect. Also check for orphaned exposer pods:
`kubectl get pods -n velero` — pods named like a PVB that have been running
longer than the backup they belong to.

### Fix

Only when no backup is running (`kubectl get backups.velero.io -n velero`
shows no `InProgress`):

```bash
kubectl delete podvolumebackups.velero.io -n velero <pvb-name> ...
```

The PVBs carry the finalizer `velero.io/pod-volume-finalizer`; on delete the
node-agent aborts the data path and releases it. If the delete hangs, patch
the finalizer. The exposer pod disappears with the PVB. No backup data is
lost — hanging PVBs never wrote any data.

### Verify

Create a small backup against a namespace with a PVC and confirm the PVB
reaches `Completed` with `status.progress.bytesDone > 0`. Example smoke-test
backup (namespace `searxng`, `defaultVolumesToFsBackup: true`,
`snapshotVolumes: false`, `ttl: 24h`).

Important takeaway: after every node-agent rollout, always check whether any
PVBs were orphaned.
