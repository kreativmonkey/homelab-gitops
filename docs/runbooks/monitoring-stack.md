# Monitoring stack (VMAlert / Alertmanager)

## Symptom

`MonitoringVMAlertDown` or `MonitoringAlertmanagerDown`.

## Alertmanager stuck `expanding` / no notifications

If `alertmanager-n8n-webhook` is listed under `spec.secrets` but the Secret does not exist, Alertmanager never becomes ready and **all** routes (including vmalert → ntfy) stall.

```bash
kubectl get secret -n monitoring alertmanager-n8n-webhook
kubectl get vmalertmanager -n monitoring vm-am -o yaml | grep -A2 updateStatus
```

Fix: either create the secret (`apps/base/monitoring/notifications/alertmanager-n8n-webhook.secret.yaml.template`) and uncomment the `n8n-triage` route in `vm-k8s-stack/helmrelease.yaml`, or keep triage disabled (GitOps default) so only `n8n-remediation` (in-cluster URL, no extra secret) and ntfy routes apply.

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

## vmsingle CrashLoop (`read-only file system` / `flock.lock`)

VictoriaMetrics needs exclusive RW access to `/victoria-metrics-data`. If the pod loops with `read-only file system`:

```bash
kubectl delete pod -n monitoring -l app.kubernetes.io/name=vmsingle
kubectl wait -n monitoring --for=condition=ready pod -l app.kubernetes.io/name=vmsingle --timeout=120s
```

If it persists: Longhorn UI → volume for `vmsingle-*` PVC → check health; last resort detach/reattach volume or restore from backup (metrics gap).

## Flux

```bash
flux reconcile helmrelease vm-k8s-stack -n monitoring
```
