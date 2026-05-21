# n8n Workflows (AI-Ops)

| Workflow | File | Trigger | Credentials |
|----------|------|---------|-------------|
| GitOps auto-remediation | `homelab-gitops-remediation.workflow.json` | `POST /webhook/vmalert` | **None in UI** — uses `$env` from `n8n-integration-credentials` |
| Alert triage (Telegram) | `../monitoring/n8n-workflows/homelab-alert-triage.workflow.json` | SOPS URL in monitoring | Manual: OpenAI + Telegram in n8n UI |

## After deploy / upgrade

```bash
export KUBECONFIG=../homelab-infrastructure/talos/kubeconfig
just n8n-bootstrap
```

Imports (or updates) the GitOps workflow and activates it. LLM + GitHub use `LLM_API_KEY`, `LLM_BASE_URL`, `GITHUB_TOKEN` from the HelmRelease / Secret.

Full guide: [`docs/integrations/alerting-n8n-gitops-remediation.md`](../../../docs/integrations/alerting-n8n-gitops-remediation.md)

Auth (why no Authentik OIDC yet): [`docs/integrations/n8n-auth.md`](../../../docs/integrations/n8n-auth.md)
