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

- Secret `alertmanager-ntfy-credentials` (key `token`) — Bridge + Notfall-Receiver
- Test Bridge: `kubectl port-forward -n monitoring svc/ntfy-bridge 8080:8080` und AM-Webhook POST oder Test-Alert feuern
- Test ntfy direkt: `curl -H "Authorization: Bearer $TOKEN" -d "test" https://ntfy.f4mily.net/monitoring`

## Wenn die ntfy-bridge down ist

| Was | Verhalten |
|-----|-----------|
| **Neue Alerts** (CNPG, Velero, …) | VMAlert + Alertmanager werten weiter aus; Webhook an die Bridge **schlägt fehl** → **keine ntfy** bis Bridge wieder läuft |
| **Sichtbarkeit** | Alerts bleiben in Alertmanager/Grafana sichtbar |
| **Wiederholung** | Alertmanager versucht bei jeder Gruppen-Benachrichtigung erneut; nach Recovery kommen Nachrichten nach |
| **Meta-Alert `NtfyBridgeDown`** | Geht **direkt** an ntfy (JSON, Receiver `ntfy-emergency`) — du erfährst, dass die Bridge fehlt |
| **Alle anderen Alerts während Ausfall** | Erst wieder lesbar auf ntfy, wenn `deployment/ntfy-bridge` wieder 1/1 ready ist |

```bash
kubectl get deploy,po -n monitoring -l app.kubernetes.io/name=ntfy-bridge
kubectl rollout restart deployment/ntfy-bridge -n monitoring
```

## Flux

```bash
flux reconcile helmrelease vm-k8s-stack -n monitoring
```
