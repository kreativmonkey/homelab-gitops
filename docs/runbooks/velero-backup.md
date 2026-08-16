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
