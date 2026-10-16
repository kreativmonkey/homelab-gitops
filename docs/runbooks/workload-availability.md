# Deployment availability

## Symptom

`KubeDeploymentReplicasUnavailable` fires when a Deployment has fewer
available replicas than requested for 15 minutes.

## Checks

```bash
kubectl -n <namespace> describe deployment <deployment>
kubectl -n <namespace> get pods -o wide
kubectl -n <namespace> get events --sort-by=.lastTimestamp
kubectl -n <namespace> logs deployment/<deployment> --all-containers --since=30m
```

Check pod scheduling, readiness probes, recent events, and controller logs.
If the pods cannot reach the Kubernetes API after a CA rotation, follow
[`ca-rotation.md`](ca-rotation.md#nach-der-kubernetes-ca-tls-fehler-pods-neu-starten).

## Recovery

Fix the reported scheduling, configuration, or readiness problem through its
GitOps source. Restart the Deployment only when its in-memory state is stale
and the mounted configuration and credentials are already current.
