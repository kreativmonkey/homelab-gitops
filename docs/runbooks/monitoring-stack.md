# Monitoring stack (VMAlert / Alertmanager)

## Symptom

`MonitoringVMAlertDown` or `MonitoringAlertmanagerDown`.

## Checks

```bash
kubectl get pods -n monitoring
kubectl get vmalert,vmalertmanager -n monitoring
kubectl logs -n monitoring -l app.kubernetes.io/name=vmalert --tail=50
kubectl logs -n monitoring -l app.kubernetes.io/name=vmalertmanager --tail=50
```

## ntfy delivery

- Secret `alertmanager-ntfy-credentials` must exist in `monitoring`
- Topic URL: `https://ntfy.f4mily.net/monitoring`
- Test publish (replace token locally): `curl -H "Authorization: Bearer $TOKEN" -d "test" https://ntfy.f4mily.net/monitoring`

## Flux

```bash
flux reconcile helmrelease vm-k8s-stack -n monitoring
```
