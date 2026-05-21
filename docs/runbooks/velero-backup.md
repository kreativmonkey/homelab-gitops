# Velero backup issues

## Symptom

`VeleroBackupFailures` or `VeleroBackupStale`.

## Checks

```bash
kubectl get backup,backupstoragelocation -n velero
kubectl logs -n velero deploy/velero --tail=100
velero backup get
```

## Remediation

- Confirm `velero-credentials` secret and BSL phase `Available`
- Re-run failed schedule: `velero backup create --from-schedule <schedule>`
