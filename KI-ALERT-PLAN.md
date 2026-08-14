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

### Phase 4 — Flux-GitOps-Alerts

Anlass (14.08.2026): PR #661 hat die PVC `backup-offsite/nextcloud-offsite-staging`
eingeführt; TrueNAS lehnte die Provisionierung ab (`>80% VOLUME`), die PVC blieb
`Pending`. Der Health-Check der Kustomization `infra-base` lief dadurch dauerhaft
in den 5-Minuten-Timeout und blieb auf `Ready=Unknown`. Weil `infra-main`, `apps`
und `apps-monitoring-rules` per `dependsOn` daran hängen, standen die drei auf
`Ready=False` mit `dependency ... is not ready`. Flux hat fünf Stunden lang nichts
mehr aus Git ausgerollt, ohne jede Meldung.

| Task | Status |
|------|--------|
| `apps/base/monitoring/extra-scrapes/flux-vmpodscrape.yaml` (gotk-Metriken, `honorLabels: true`) | ✅ |
| `apps/base/monitoring/rules/flux-vmrule.yaml` (4 Alerts: `FluxControllerDown`, `FluxReconcileFailing`, `FluxReconcileStalled`, `FluxSuspended`) | ✅ |
| Eigener ntfy-Receiver | nicht nötig — bestehende Route über `severity` + `homelab_owner: platform` greift bereits |
| Runbook `docs/runbooks/flux-reconcile.md` | ✅ |

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

**KI-Workflow today:** Issue → AI-Agent Plan → Manifest Update → PR → CI validation.

**Alert-Workflow:** AM → n8n (LLM) → Telegram; optional Remediation nur `NtfyBridgeDown` mit Label `homelab/auto_triage=true`.

---

### Phase 7 — Generischer Job-Watchdog + Dead-Man's-Switch

CronJobs (Offsite-Backups, Authentik-Blueprint-Check) hatten kein Alerting:
ein Job, der scheitert, suspendiert wird, aus Git verschwindet oder nie
anläuft, blieb unbemerkt. Statt Alerts pro Job melden sich CronJobs per Label
(`homelab.f4mily.net/watchdog`) am generischen Watchdog an. Zusätzlich sichert
ein Dead-Man's-Switch über Home Assistant die gesamte Alerting-Kette selbst ab
— fällt vmalert, Alertmanager oder die ntfy-bridge komplett aus, bleibt sonst
auch das unbemerkt.

| Alert | Status |
|-------|--------|
| `WatchdogBlind` | ✅ |
| `WatchdogConfigInvalid` | ✅ |
| `WatchdogJobFailed` | ✅ |
| `WatchdogJobStale` | ✅ |
| `WatchdogCronJobSuspended` | ✅ |
| `WatchdogJobStuck` | ✅ |
| `WatchdogCronJobDisappeared` | ✅ |
| `Watchdog` (Dead-Man's-Switch, `severity: none`) | ✅ |

Angemeldete Jobs: `backup-offsite/immich-offsite-backup` (32/6),
`backup-offsite/nextcloud-offsite-backup` (32/6),
`backup-offsite/offsite-restore-verify` (174/5),
`authentik/authentik-blueprint-check` (3/1).

**Abgelöst:** `apps/base/monitoring/rules/authentik-vmrule.yaml` ist entfallen
— `AuthentikBlueprintCheckFailed` und `AuthentikBlueprintCheckStale` sind im
generischen Watchdog aufgegangen (`WatchdogJobFailed`/`WatchdogJobStale` für
`authentik/authentik-blueprint-check`).

Doku: [`docs/runbooks/job-watchdog.md`](docs/runbooks/job-watchdog.md),
[`docs/integrations/dead-mans-switch-homeassistant.md`](docs/integrations/dead-mans-switch-homeassistant.md).

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
├── rules/
│   ├── platform-p0-vmrule.yaml
│   ├── job-watchdog-vmrule.yaml        # generischer Job-Watchdog (Phase 7)
│   ├── dead-mans-switch-vmrule.yaml    # Watchdog/vector(1) -> HA-Webhook (Phase 7)
│   └── flux-vmrule.yaml                # Flux-GitOps-Alerts (Phase 4)
└── extra-scrapes/
    └── flux-vmpodscrape.yaml           # gotk_* Metriken (Phase 4)

docs/runbooks/
├── cnpg-cluster-offline.md
├── cnpg-backup-stale.md
├── velero-backup.md
├── node-resources.md
├── monitoring-stack.md
├── job-watchdog.md                        # Phase 7
└── flux-reconcile.md                      # Phase 4

docs/integrations/
└── dead-mans-switch-homeassistant.md       # Phase 7
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
| 2026-08-14 | Flux-GitOps-Alerts (Phase 4): PR #661 hat eine Pending-PVC eingeführt (TrueNAS >80%-VOLUME-Limit), `infra-base` hing 5h im Health-Check-Timeout (`Ready=Unknown`), `infra-main`/`apps`/`apps-monitoring-rules` dadurch `Ready=False` — Flux rollte fünf Stunden lang nichts mehr aus Git aus, ohne Meldung. Fix: `flux-vmpodscrape.yaml` + 4 Alerts (`FluxControllerDown`, `FluxReconcileFailing`, `FluxReconcileStalled`, `FluxSuspended`) in `flux-vmrule.yaml`, Runbook `flux-reconcile.md` |
| 2026-08-14 | Generischer Job-Watchdog (7 Alerts, Opt-in per Label) + Dead-Man's-Switch über Home Assistant (Phase 7); `rules/authentik-vmrule.yaml` entfernt, in Watchdog aufgegangen |
| 2026-05-30 | kubeApiServer-Scrape aus; Script `purge-chart-vmrules.sh` für verwaiste VMRules |
| 2026-06-02 | `defaultRules.enabled: false` — `create: false` allein ließ Chart-VMRules (ScrapePoolHasNoTargets) |
| 2026-05-30 | Fix `defaultRules.create: false`; Talos control-plane scrapes aus |
| 2026-05-30 | CNPG VMPodScrape mit namespace/pod-Relabeling; enablePodMonitor deaktiviert |
| 2026-05-21 | Phase 1–3 implementiert, Plan angelegt |
