# Runbook: Pod OOMKilled / CrashLoopBackOff

## Symptoms

- Alert `KubePodOOMKilled` or `KubePodCrashLoopBackOff`
- ntfy + optional GitHub PR from n8n auto-remediation

## Immediate checks

```bash
kubectl -n <namespace> describe pod <pod>
kubectl -n <namespace> logs <pod> -c <container> --previous
```

## Auto-remediation

If enabled, Alertmanager posts to n8n → LLM proposes a Git patch → GitHub PR (`kreativmonkey/homelab-gitops`).

Alerts: `KubePodOOMKilled`, `KubePodCrashLoopBackOff` (2m), optional chart alert `KubePodCrashLooping`.

**Do not merge** the PR without reviewing the diff. Flux applies after merge.

Wenn n8n nicht startet: Runbook [monitoring-stack.md](./monitoring-stack.md#n8n-crashloop--oom-remediation) und `just n8n-bootstrap`.

## Manual fixes

| Cause | Action |
|-------|--------|
| OOM | Raise memory limits/requests in Git (`apps/base/...`) |
| Bad image/config | Fix env/configmap; roll deployment |
| Dependency down | Fix CNPG/Redis/etc. first |

## Disable auto PRs

Remove route `n8n-remediation` in `vm-k8s-stack/helmrelease.yaml` or deactivate the n8n workflow.
