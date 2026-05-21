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

Alertmanager → `ntfy-bridge` (ClusterIP) → `https://ntfy.f4mily.net/monitoring` (lesbare Titel/Texte).

- Secret `alertmanager-ntfy-credentials` (key `token`) — nur für die Bridge
- Test Bridge: `kubectl port-forward -n monitoring svc/ntfy-bridge 8080:8080` und AM-Webhook POST oder Test-Alert feuern
- Test ntfy direkt: `curl -H "Authorization: Bearer $TOKEN" -d "test" https://ntfy.f4mily.net/monitoring`

## Flux

```bash
flux reconcile helmrelease vm-k8s-stack -n monitoring
```
