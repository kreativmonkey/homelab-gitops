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

## n8n CrashLoop / OOM remediation

VMAlert fires → Alertmanager receiver `n8n-remediation` → `http://n8n-app.ai-ops.svc.cluster.local:5678/webhook/vmalert`.

**Symptom:** ntfy zeigt CrashLoop, aber n8n **Executions** bleiben leer.

**Häufige Ursachen:**

| Ursache | Prüfung / Fix |
|---------|----------------|
| Route matcht nicht | `alertmanager_notifications_total{receiver="n8n-remediation"}` sollte >0 sein nach Alert |
| Workflow nicht importiert | `just n8n-bootstrap` (oder `N8N_API_KEY` + API-Import) |
| Webhook-Test | `just n8n-test-webhook` → `{"message":"Workflow was started"}` |

```bash
# Metrik (über metrics.cluster.f4mily.net oder Port-Forward)
curl -sk --resolve metrics.cluster.f4mily.net:443:192.168.10.41 \
  'https://metrics.cluster.f4mily.net/api/v1/query?query=sum(alertmanager_notifications_total{receiver="n8n-remediation"})'
```

Nach GitOps-Änderung an `vm-k8s-stack/helmrelease.yaml`:

```bash
flux reconcile helmrelease vm-k8s-stack -n monitoring
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

## Stale chart default alerts (KubeControllerManager*, KubeJobFailed, …)

Symptom: Alerts from `runbooks.prometheus-operator.dev` despite intending to use only P0 VMRules.

Cause: `defaultRules.enabled: false` is ignored by `victoria-metrics-k8s-stack` — use **`defaultRules.create: false`**. After fixing Helm values, **orphaned VMRule CRs may remain** until deleted once.

One-time cleanup (keeps `homelab-platform-*` / `workload-remediation` VMRules):

```bash
./scripts/monitoring/purge-chart-vmrules.sh monitoring
flux reconcile helmrelease vm-k8s-stack -n monitoring
kubectl get vmrule -n monitoring
# Expect only homelab-platform-p0 and homelab-workload-remediation — no vm-k8s-stack-*.rules
```

Talos: keep `kubeApiServer`, `kubeControllerManager`, `kubeScheduler`, and `kubeEtcd` scrapes disabled — control-plane Endpoints are not reliably reachable from vmagent (→ `TargetDown`, `KubeAPIInstanceUnreachable`).

If `KubeJobFailed` persists **after** VMRule cleanup, check real Jobs (not monitoring noise):

```bash
kubectl get jobs -A --field-selector status.successful!=1
kubectl logs -n nextcloud job/<name>
kubectl logs -n renovate job/<name>
```

## Flux

```bash
flux reconcile helmrelease vm-k8s-stack -n monitoring
```
