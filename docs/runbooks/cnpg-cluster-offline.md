# CNPG cluster offline

## Symptom

Alert `CNPGClusterOffline` or `CNPGClusterInstanceDown`.

## Checks

```bash
kubectl get cluster -n cnpg-system
kubectl get pods -n cnpg-system -l cnpg.io/cluster
kubectl logs -n cnpg-system -l cnpg.io/podRole=instance --tail=80
```

## Common causes

- Longhorn volume not attached
- Node pressure / eviction
- Failed bootstrap or recovery overlay left active

## Escalation

See [cnpg-s3-dr.md](../disaster-recovery/cnpg-s3-dr.md) if the cluster must be recovered from S3.
