# KI-Alert-Plan — Homelab Monitoring & Benachrichtigungen

Fortschritt für Alerting (VictoriaMetrics → Alertmanager → ntfy) und spätere KI-Triage.

**Stand:** 2026-05-21

---

## Entscheidungen

| Thema | Wahl |
|-------|------|
| Metrik-Stack | VictoriaMetrics k8s-stack (`apps/base/monitoring/vm-k8s-stack/`) |
| Benachrichtigung | ntfy `https://ntfy.f4mily.net/monitoring` (Bearer-Token in SOPS) |
| Regeln Plattform | `apps/base/monitoring/rules/platform-p0-vmrule.yaml` |
| Regeln Chart-Defaults | `defaultRules` in HelmRelease (gefiltert) |
| Runbooks | `docs/runbooks/` |
| KI-Agent (Cursor/OpenCode) | Schreibt/ändert Manifeste — **kein** Webhook-Empfänger im Cluster |

> **Sicherheit:** API-Token nur in `alertmanager-ntfy-credentials.secret.yaml` (SOPS). Nach Chat-Leak Token in ntfy rotieren und Secret neu verschlüsseln.

---

## Phasen & Fortschritt

### Phase 1 — Pipeline (Alertmanager + ntfy)

| Task | Status |
|------|--------|
| Alertmanager in `vm-k8s-stack` aktivieren | ✅ |
| `vmalert` Blackhole entfernen (AM-Notifier via Chart) | ✅ |
| SOPS-Secret `alertmanager-ntfy-credentials` | ✅ |
| Routing critical / warning / info + Inhibition | ✅ |
| Template für Secret-Neuerstellung | ✅ |

**Nach Flux-Reconcile prüfen:**

```bash
kubectl get vmalertmanager,vmalert -n monitoring
kubectl port-forward -n monitoring svc/vmalertmanager-vm-k8s-stack 9093:9093
# AM UI → Status → config zeigt receiver ntfy-monitoring
```

---

### Phase 2 — Repo-Struktur

| Task | Status |
|------|--------|
| `apps/base/monitoring/kustomization.yaml` (stack + notifications + rules) | ✅ |
| `apps/base/monitoring/notifications/` | ✅ |
| `apps/base/monitoring/rules/` | ✅ |
| Overlay `apps/overlays/main` → `../../base/monitoring` | ✅ |
| Velero ServiceMonitor wieder aktiv | ✅ |
| Nginx Ingress VMServiceScrape wieder aktiv | ✅ |
| CNPG VMPodScrape + namespace/pod relabeling | ✅ |
| `defaultRules` Noise-Reduktion (K3s/Talos) | ✅ |

---

### Phase 3 — P0-Regeln (homelab/platform)

| Alert | Status |
|-------|--------|
| CNPGClusterOffline | ✅ |
| CNPGClusterInstanceDown | ✅ |
| CNPGBackupStale | ✅ |
| VeleroBackupFailures | ✅ |
| VeleroBackupStale | ✅ |
| NodeMemoryCritical | ✅ |
| NodeDiskCritical | ✅ |
| MonitoringVMAlertDown | ✅ |
| MonitoringAlertmanagerDown | ✅ |

Runbooks für alle P0-Alerts angelegt.

---

### Phase 4 — Flux-GitOps-Alerts (offen)

| Task | Status |
|------|--------|
| `infrastructure/base/flux-notifications/` Provider + Alert | ⬜ |
| Eigener ntfy-Receiver `homelab-gitops` | ⬜ |

---

### Grafana ↔ Authentik (2026-05-21)

| Task | Status |
|------|--------|
| Grafana Generic OAuth in HelmRelease | ✅ |
| Authentik Blueprint (App + Provider) | ✅ |
| SOPS `grafana-authentik-oauth` | ✅ (lokal erzeugt — committen) |
| Entitlements in Authentik UI binden | ⬜ manuell |
| Provider `client_secret` mit SOPS abgleichen | ⬜ manuell |

Siehe [`docs/integrations/grafana-authentik.md`](docs/integrations/grafana-authentik.md).

---

### Phase 5 — Lärm reduzieren & Lesbarkeit (in Arbeit)

| Task | Status |
|------|--------|
| `defaultRules.create: false` + `enabled: false` (nur P0-VMRules) | ✅ |
| Alertmanager: Default → blackhole, nur critical/warning → ntfy | ✅ |
| längere `group_wait` / `repeat_interval` | ✅ |
| ntfy-Bridge (`apps/base/monitoring/ntfy-bridge/`) | ✅ |
| NtfyBridgeDown + Notfall-Receiver (direkt ntfy, JSON) | ✅ |
| cert-manager / external-dns ServiceMonitors | ⬜ |
| Goloom / kritische Apps (up, 5xx) | ⬜ |

---

### Phase 6 — KI-Triage (n8n + Telegram)

| Task | Status |
|------|--------|
| n8n-Workflow `homelab-alert-triage.workflow.json` | ✅ |
| Doku `docs/integrations/alerting-n8n-telegram-triage.md` | ✅ |
| AM-Receiver `n8n-triage` (parallel ntfy, `continue: true`) | ✅ |
| SOPS `alertmanager-n8n-webhook` (volle Webhook-URL) | ⬜ manuell |
| Telegram-Bot + LLM-Credentials in n8n | ⬜ manuell |
| Remediation-API (Auto-Fix Allowlist) | ⬜ Phase 2 |
| Human-in-the-Loop (Telegram-Buttons / Wait) | ⬜ Phase 2 |

**KI-Workflow heute:** Issue → `.opencode/agents/architect` Plan → `k8s-specialist` YAML → PR → `integration-test` CI.

**Alert-Workflow:** AM → n8n (LLM) → Telegram; optional Remediation nur `NtfyBridgeDown` mit Label `homelab/auto_triage=true`.

---

## Dateien (Referenz)

```
apps/base/monitoring/
├── kustomization.yaml
├── vm-k8s-stack/helmrelease.yaml      # AM + defaultRules + n8n-triage
├── n8n-workflows/homelab-alert-triage.workflow.json
├── notifications/
│   ├── alertmanager-ntfy-credentials.secret.yaml
│   └── alertmanager-n8n-webhook.secret.yaml  # nach sops-create
└── rules/
    └── platform-p0-vmrule.yaml

docs/runbooks/
├── cnpg-cluster-offline.md
├── cnpg-backup-stale.md
├── velero-backup.md
├── node-resources.md
└── monitoring-stack.md
```

---

## Nächste Schritte (Betrieb)

1. Push → Flux reconcile `apps` Kustomization
2. Test: `curl -H "Authorization: Bearer <token>" -d "Homelab alerting test" https://ntfy.f4mily.net/monitoring`
3. In Grafana/VM prüfen, ob CNPG/Velero-Metriken ankommen; sonst Regeln anpassen
4. Token rotieren falls exponiert

---

## Changelog

| Datum | Änderung |
|-------|----------|
| 2026-05-30 | kubeApiServer-Scrape aus; Script `purge-chart-vmrules.sh` für verwaiste VMRules |
| 2026-06-02 | `defaultRules.enabled: false` — `create: false` allein ließ Chart-VMRules (ScrapePoolHasNoTargets) |
| 2026-05-30 | Fix `defaultRules.create: false`; Talos control-plane scrapes aus |
| 2026-05-30 | CNPG VMPodScrape mit namespace/pod-Relabeling; enablePodMonitor deaktiviert |
| 2026-05-21 | Phase 1–3 implementiert, Plan angelegt |
