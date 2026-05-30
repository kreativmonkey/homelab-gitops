# n8n Workflows (Monitoring)

| Datei | Beschreibung |
|-------|----------------|
| `homelab-alert-triage.workflow.json` | Alertmanager → LLM-Triage → Telegram (+ optional Remediation) |
| `homelab-pr-auto-merge.workflow.json` | Schedule (30min) → GitHub PR Merge + Telegram Notify |

Import in n8n, Credentials setzen, Workflow aktivieren.

Anleitung: [`docs/integrations/alerting-n8n-telegram-triage.md`](../../../docs/integrations/alerting-n8n-telegram-triage.md)
