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

## n8n Alert Triage (Telegram / LLM)

VMAlert → Alertmanager receiver `n8n-triage` → `http://n8n-app.ai-ops.svc.cluster.local:5678/webhook/homelab-alert?webhookSecret=…`

**Symptom:** ntfy kommt, aber n8n zeigt nur **Homelab GitOps Remediation** oder gar keine Triage-Executions.

| Ursache | Fix |
|---------|-----|
| Secret-URL Pfad statt Query (`…/homelab-alert/SECRET`) | `just alertmanager-n8n-webhook-url` + Flux reconcile; AM-Pod neu starten |
| Route `n8n-remediation` aktiv | Standard: deaktiviert — nur `n8n-triage` für `homelab/owner=platform` |
| Workflow Credentials | Telegram + OpenAI in n8n UI (siehe `docs/integrations/alerting-n8n-telegram-triage.md`) |

Test aus dem Cluster:

```bash
URL=$(kubectl get secret -n monitoring alertmanager-n8n-webhook -o jsonpath='{.data.url}' | base64 -d)
kubectl exec -n monitoring deploy/vmalert-vm-k8s-stack-victoria-metrics-k8s-stack -- \
  wget -qO- --post-data='{"status":"firing","alerts":[{"labels":{"alertname":"Test","severity":"critical","homelab/owner":"platform"}}]}' \
  --header='Content-Type: application/json' "$URL"
# Erwartung: {"message":"Workflow was started"}
```

## n8n CrashLoop / OOM GitOps remediation (opt-in)

Direkt-Webhook `POST /webhook/vmalert` ist **nicht** mehr an Alertmanager gebunden (vermeidet parallele Runs neben Triage).

Aktivierung: Route `n8n-remediation` in `vm-k8s-stack/helmrelease.yaml` wieder einkommentieren — siehe `docs/integrations/alerting-n8n-gitops-remediation.md`.

**Symptom:** ntfy zeigt CrashLoop, aber n8n **Executions** bleiben leer (wenn Remediation-Route aktiv).

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

## Stale chart default alerts (KubeControllerManager*, ScrapePoolHasNoTargets, …)

Symptom: Alerts from chart VMRules (`ScrapePoolHasNoTargets`, `KubeJobFailed`, …) despite intending to use only P0 VMRules.

Cause: the chart template prefers **`defaultRules.enabled`** (default `true`). Setting only `create: false` still renders chart VMRules including `ScrapePoolHasNoTargets` (`vmagent` group). After fixing Helm values, **orphaned VMRule CRs may remain** until deleted once.

Git fix (both required):

```yaml
defaultRules:
  create: false
  enabled: false
```

One-time cleanup (keeps `homelab-platform-*` / `workload-remediation` VMRules):

```bash
./scripts/monitoring/purge-chart-vmrules.sh monitoring
flux reconcile helmrelease vm-k8s-stack -n monitoring
kubectl get vmrule -n monitoring
# Expect only homelab-platform-p0 and homelab-workload-remediation — no vm-k8s-stack-*.rules
```

## ScrapePoolHasNoTargets (vmagent empty scrape pools)

Symptom: `ScrapePoolHasNoTargets` — vmagent has a scrape job with 0 discovered targets for 30m+.

Common homelab causes:

| Cause | Typical `scrape_job` / pool names |
|-------|-----------------------------------|
| Talos control-plane scrapes disabled in Git but **orphan VMServiceScrape CRs** remain | `serviceScrape/monitoring/vm-k8s-stack-kube-controller-manager/0`, `…-kube-scheduler/0`, `…-kube-etcd/0` (often **3 alerts**) |
| Wrong port on a Pod/Service endpoint | custom `VMPodScrape` / sidecar port with no `/metrics` |
| Selector mismatch | `extra-scrapes` CR finds no Services/Pods |

Talos: keep `kubeApiServer`, `kubeControllerManager`, `kubeScheduler`, and `kubeEtcd` **disabled** in `helmrelease.yaml` — control-plane metrics are not reachable via standard Endpoints (empty pools or `TargetDown`).

Diagnose (needs cluster access):

```bash
kubectl get vmpodscrape,vmservicescrape,vmstaticscrape,vmprobe -A
# vmagent targets UI (port-forward vmagent pod :8429)
kubectl port-forward -n monitoring svc/vmagent-vm-k8s-stack 8429:8429
# open http://127.0.0.1:8429/targets — search "0/0 up"
curl -s 'http://127.0.0.1:8429/metrics' | grep 'vm_promscrape_scrape_pool_targets{.*} 0$' || true
curl -sG 'http://127.0.0.1:8429/api/v1/query' --data-urlencode \
  'query=sum(vm_promscrape_scrape_pool_targets) without(status,instance,pod) == 0'
```

Remove orphan Talos control-plane scrapes (after Git has them `enabled: false`):

```bash
./scripts/monitoring/purge-talos-vmservicescrapes.sh monitoring
flux reconcile helmrelease vm-k8s-stack -n monitoring
```

If `KubeJobFailed` persists **after** VMRule cleanup, check real Jobs (not monitoring noise):

```bash
kubectl get jobs -A --field-selector status.successful!=1
kubectl logs -n nextcloud job/<name>
kubectl logs -n renovate job/<name>
```

**Nextcloud:** five alerts often = five retained failed CronJob runs (`failedJobsHistoryLimit: 5`). See [nextcloud-cronjob-failed.md](nextcloud-cronjob-failed.md).

## Flux

```bash
flux reconcile helmrelease vm-k8s-stack -n monitoring
```
