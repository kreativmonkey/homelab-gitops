# CNPG cluster offline

## Symptom

Alert `CNPGClusterOffline` or `CNPGClusterInstanceDown`.

## Checks

```bash
kubectl get cluster -n cnpg-system
kubectl get pods -n cnpg-system -l cnpg.io/cluster
kubectl get vmpodscrape -n cnpg-system cnpg-clusters
kubectl logs -n cnpg-system -l cnpg.io/podRole=instance --tail=80
```

In Grafana / VictoriaMetrics:

```promql
cnpg_collector_up{namespace="cnpg-system"}
```

Expect one series per CNPG instance with `namespace`, `pod`, and `cluster` labels. If the series exist without `namespace`, check `apps/base/monitoring/extra-scrapes/cnpg-vmpodscrape.yaml` relabeling and that `enablePodMonitor: false` on Cluster CRs (avoids duplicate/conflicting PodMonitors).

## Common causes

- Longhorn volume not attached
- Node pressure / eviction
- Failed bootstrap or recovery overlay left active

## Escalation

See [cnpg-s3-dr.md](../disaster-recovery/cnpg-s3-dr.md) if the cluster must be recovered from S3.
