# Node memory or disk critical

## Symptom

`NodeMemoryCritical` or `NodeDiskCritical`.

## Checks

```bash
kubectl top nodes
kubectl get pods -A --field-selector spec.nodeName=<node> -o wide
```

Inspect Longhorn volumes and CNPG PVC growth on the affected node.

## Remediation

- Evict non-critical workloads
- Expand PVC or prune metrics/logs retention in VictoriaMetrics/Grafana
