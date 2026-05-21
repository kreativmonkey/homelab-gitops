# CNPG backup stale

## Symptom

Alert `CNPGBackupStale` — no recent backup in object store.

## Checks

```bash
kubectl get scheduledbackup,backup -n cnpg-system
kubectl describe cluster homelab-postgres -n cnpg-system
```

Verify S3 credentials secret `cnpg-barman-s3-credentials` and Garage endpoint reachability.

## Remediation

Trigger manual backup per [cnpg-s3-dr.md](../disaster-recovery/cnpg-s3-dr.md) troubleshooting section.
