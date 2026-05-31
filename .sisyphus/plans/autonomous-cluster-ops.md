# Plan: Autonomous Cluster Operations

**Ziel:** KI-gestützte Alert-Triage, PR-Review + Auto-Merge, schrittweise
mehr Autonomie — ohne Produktionsbeeinträchtigung.

**Prinzip:** Jeder Schritt ist isoliert rückrollbar. Zuerst Read-only
(Triage, Review), dann Write (Auto-Merge, Auto-Remediation).

---

## Phase A — Alert-Triage via Telegram aktivieren (Read-only)

**Risiko:** Kein Eingriff in Cluster. Nur zusätzlicher Notification-Kanal.

### A1 SOPS-Secret `alertmanager-n8n-webhook` erstellen

```bash
cd apps/base/monitoring/notifications
# SOPS_AGE_KEY_FILE gesetzt
just sops-create alertmanager-n8n-webhook monitoring \
  url='https://n8n.cluster.f4mily.net/webhook/homelab-alert/DEIN_ZUFAELLIGES_SECRET'
```

Das Secret enthält die komplette URL. Alertmanager mountet es als
`/etc/vm/secrets/alertmanager-n8n-webhook/url` und liest daraus die
Ziel-URL.

**WEBHOOK_SECRET in n8n:** Das Secret (`DEIN_ZUFAELLIGES_SECRET`) muss
auch als n8n-Environment-Variable `WEBHOOK_SECRET` gesetzt werden.
Dazu in n8n UI → Settings → Environment Variables → `WEBHOOK_SECRET`
eintragen.

### A2 Secret in Kustomization registrieren

`apps/base/monitoring/notifications/kustomization.yaml`:
`alertmanager-n8n-webhook.secret.yaml` zu resources hinzufügen.

### A3 n8n-Triage-Route im Alertmanager aktivieren

`apps/base/monitoring/vm-k8s-stack/helmrelease.yaml`:
- Commented-Block `n8n-triage` receiver (Zeilen 137-141, 174-177) einkommentieren
- Damit Alerts mit Label `homelab/owner=platform` und `severity=critical|warning`
  parallel zu ntfy auch an n8n gehen

### A4 Telegram-Credential prüfen

User hat bereits Telegram-Bot-Token in n8n Credentials.
`TELEGRAM_CHAT_ID` als Environment-Variable in n8n setzen.

### A5 Flux reconcile

```bash
flux reconcile kustomization apps --with-source
```

### A6 Test

```bash
# Webhook direkt testen
curl -X POST "https://n8n.cluster.f4mily.net/webhook/homelab-alert/DEIN_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"status":"firing","alerts":[{"labels":{"alertname":"TestAlert","severity":"warning","homelab/owner":"platform","homelab/auto_triage":"true"},"annotations":{"summary":"Test from plan"}}]}'
```

Erwartung: Telegram-Nachricht mit LLM-Triage-Ergebnis.

---

## Phase B — PR Review Automation (Read-only)

**Risiko:** Nur Kommentare auf PRs. Kein Merge.

### B1 GitHub-App oder Webhook-Receiver

Zwei Optionen:

| Option | Vorteil | Nachteil |
|--------|---------|----------|
| **B1a n8n-Webhook** | Läuft bereits, hat LLM+GitHub-Token | n8n ist single-replica, kein LB |
| **B1b Forgejo Actions + OpenCode** | Nativ im CI, kein extra Service | OpenCode müsste auf Runner laufen |

**Empfehlung: B1a n8n-Webhook** — weil LLM + GitHub-Token + ntfy-Error-Reporting
bereits existieren.

Neuer n8n-Workflow: `homelab-gitops-pr-review`
- Trigger: GitHub Webhook (`pull_request` opened/synchronize)
- LLM analysiert Diff (geändert YAML-Files, Werte, Secrets)
- Output: `review_decision` in `{approve, comment, request_changes}`
- Post Review via GitHub REST API (`/repos/{owner}/{repo}/pulls/{number}/reviews`)

### B2 Review-Scoring (Risikobewertung)

LLM klassifiziert PRs nach Risiko:

| Risiko | Beispiele | Aktion |
|--------|-----------|--------|
| **low** | Image-Tag-Bump (patch), ConfigMap-Wert, Kommentar | Auto-Approve + Auto-Merge (Phase C) |
| **medium** | Env-Var-Änderung, Resource-Limit, Helm-Values | Comment + warten |
| **high** | RBAC, NetworkPolicy, StorageClass, SOPS-Secrets | Request Changes |
| **blocker** | Neue App, Namespace, ClusterRole | Mensch entscheidet |

### B3 Guardrails

- Nie Secrets bewerten (SOPS encrypted → kann LLM nicht lesen)
- Nie RBAC/NetworkPolicy/K8s-Auth automatisch ändern
- Änderungen an `infrastructure/` → immer `high` Risiko
- Review-Allowlist: nur `apps/base/*` für Auto-Review
- Bei LLM-Unsicherheit → Fallback auf `needs_human`

### B4 n8n-Credentials

Nötig:
- GitHub-Token: bereits vorhanden (`n8n-integration-credentials`)
- LLM: bereits vorhanden
- Keine neuen Secrets im Cluster nötig

### B5 Integration mit CI

CI-Status (`pr-validation.yaml`) als Input-Faktor für Merge-Entscheidung:
- Wenn CI failed → kein Merge, auch wenn LLM approve
- n8n fragt GitHub Checks API ab (`/repos/{owner}/{repo}/commits/{sha}/check-runs`)

---

## Phase C — Auto-Merge Low-Risk PRs (Write)

**Risiko:** Niedrig, weil auf `low`-Risiko-Klassifizierung beschränkt.

### C1 Entscheidungsmatrix

| CI pass? | LLM-Risiko | Merge? |
|----------|-----------|--------|
| ✅ | low | ✅ Auto-Merge |
| ✅ | medium | ❌ Nur Review |
| ✅ | high | ❌ Request Changes |
| ❌ | egal | ❌ Nie |
| ⚠️ (Renovate patch) | low | ✅ Auto-Merge (erweitert bestehende Renovate-Regel) |

### C2 Merge via GitHub API

```http
PUT /repos/{owner}/{repo}/pulls/{number}/merge
```

Merge-Methode: `squash` (ein Commit, saubere History).

### C3 Erweiterung der Renovate-Auto-Merge-Regeln

Bestehend (patch für homepage, uptime-kuma). Neu:
- Alle Image-Tag-Patches wo LLM `low` bewertet
- Helm-Chart-Patches mit `low` Risiko
- ConfigMap-Werte mit `low` Risiko

Ausschlüsse:
- `renovate.json` Änderungen
- `.forgejo/workflows/` oder `.github/workflows/` Änderungen
- `infrastructure/` Änderungen

---

## Phase D — Auto-Remediation erweitern

**Risiko:** Erhöht sich mit jedem neuen Alert-Typ im Allowlist.

### D1 Bestehend (keine Änderung nötig)

- OOMKilled → n8n → GitHub PR (bereits aktiv)
- CrashLoopBackOff → n8n → GitHub PR (bereits aktiv)
- CrashLooping → n8n → GitHub PR (bereits aktiv)

### D2 Alert-Triage via Telegram (Phase A liefert Basis)

Nach Phase A bekommen alle P0-Alerts (CNPG, Velero, Node, Monitoring)
eine LLM-Bewertung per Telegram. Das ist bereits Read-only.

### D3 Auto-Fix-Allowlist erweitern (nach Beobachtung)

Folgende Alerts könnten nach einer Testphase auf Auto-Fix gesetzt
werden:

| Alert | Aktion | Voraussetzung |
|-------|--------|--------------|
| `NtfyBridgeDown` | `rollout restart deployment/ntfy-bridge` | Remediation-API (Phase D4) |
| `VeleroBackupFailure` | `rollout restart deployment/velero` | Nach Testphase manuell freigeben |
| `MonitoringAlertmanagerDown` | Neu starten | Nach Testphase |

### D4 Remediation-API (für kubectl-Zugriff)

Kleiner Service in `ai-ops` Namespace:
- POST `/v1/remediate` mit `{action, namespace, resource}`
- JWT-validierung (n8n hat den Key)
- RBAC: nur `get pods`, `delete pod`, `rollout restart`
- Allowlist: `monitoring`, `ai-ops` Namespaces (nicht `tandoor`, `jellyfin`, etc.)
- Audit-Log via ntfy

**Zuerst Phase A+B umsetzen, dann Remediation-API bauen.**

---

## Plan-Zusammenfassung (Reihenfolge)

```
Woche 1:
  A1 SOPS-Secret erstellen (5 Min)
  A2 Kustomization anpassen (1 Min)
  A3 AM-Route aktivieren (2 Min)
  A4 WEBHOOK_SECRET in n8n setzen (1 Min)
  A5 Flux reconcile (30s)
  A6 Test (5 Min)
  → Telegram-Triage läuft, kein Produktionsrisiko

Woche 2:
  B1-B5 PR-Review-Workflow in n8n erstellen
  → PRs werden reviewed, nichts gemerged

Woche 3:
  C1-C3 Auto-Merge low-risk aktivieren
  → PR-Review + Auto-Merge läuft

Nach Beobachtungsphase:
  D3-D4 Auto-Fix-Allowlist erweitern + Remediation-API
  → Cluster wird autonomer
```

---

## Sicherheitsprinzipien (für den ganzen Plan)

1. **Read-only first**: Erste Version jedes Features nur beobachten.
   Write-Funktion erst nach Testphase freischalten.
2. **Allowlist statt Denylist**: Explizit erlaubte Alert-Typen/PR-Änderungen.
   Alles andere → Mensch.
3. **CI-Gate**: Nie mergen ohne grüne CI. Nie remedieren ohne aktuellen
   Cluster-State.
4. **Rückrollbarkeit**: Jede Änderung ist ein einzelner Commit. Ein
   `git revert` reicht.
5. **Kein Cluster-Admin für AI**: n8n & Co. haben nur minimale RBAC.
   Remediation-API bekommt explizite Allowlist (Namespace, Action, Resource).
6. **Produktions-Namespaces geschützt**: `tandoor`, `jellyfin`, `nextcloud`,
   `immich`, `forgejo`, `cnpg-system` sind nie im Auto-Fix-Allowlist
   der Remediation-API.
