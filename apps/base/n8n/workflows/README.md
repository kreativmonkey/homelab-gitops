# n8n Workflows (AI-Ops)

| Workflow | File | Trigger | Credentials |
|----------|------|---------|-------------|
| GitOps auto-remediation | `homelab-gitops-remediation.workflow.json` | `POST /webhook/vmalert` | **None in UI** — `$env` from `n8n-integration-credentials` |
| GitOps remediation **errors** | `homelab-gitops-remediation-error.workflow.json` | Error Trigger (linked workflow) | `$env` `NTFY_URL`, `NTFY_TOKEN` |
| Alert triage (Telegram) | `../monitoring/n8n-workflows/homelab-alert-triage.workflow.json` | SOPS URL in monitoring | Manual: OpenAI + Telegram in n8n UI |

## After deploy / upgrade

```bash
export KUBECONFIG=../homelab-infrastructure/talos/kubeconfig
just n8n-bootstrap
# exec fails (no route to kubelet)? → export N8N_API_KEY=… and re-run (REST API fallback)
```

Imports both workflows. With `N8N_API_KEY`, links **Error workflow** automatically. LLM/GitHub/ntfy use pod `$env` from `n8n-integration-credentials` (`github-token`, `llm-api-key`, `ntfy-url`, `ntfy-token`).

**Error notify:** When remediation fails, n8n runs `Homelab GitOps Remediation — Error Notify` → ntfy topic `monitoring` (same token as Alertmanager is fine).

Full guide: [`docs/integrations/alerting-n8n-gitops-remediation.md`](../../../docs/integrations/alerting-n8n-gitops-remediation.md)

Auth (why no Authentik OIDC yet): [`docs/integrations/n8n-auth.md`](../../../docs/integrations/n8n-auth.md)
