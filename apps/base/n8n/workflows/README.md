# n8n Workflows (AI-Ops)

| Workflow | File | Trigger |
|----------|------|---------|
| GitOps auto-remediation | `homelab-gitops-remediation.workflow.json` | `POST /webhook/vmalert` (Alertmanager) |
| Alert triage (Telegram) | `../monitoring/n8n-workflows/homelab-alert-triage.workflow.json` | SOPS URL in monitoring |

Import in n8n UI → activate → set OpenAI + GitHub PAT (Bearer) credentials.

Full guide: [`docs/integrations/alerting-n8n-gitops-remediation.md`](../../../docs/integrations/alerting-n8n-gitops-remediation.md)
