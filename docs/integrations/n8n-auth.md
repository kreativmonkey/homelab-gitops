# n8n authentication (UI vs webhooks)

## Current state

| Layer | Status |
|-------|--------|
| **Ingress** | HTTPS only (`n8n.cluster.f4mily.net`), no auth |
| **n8n UI login** | Local owner account (first setup) |
| **Authentik OIDC** | Not configured (unlike Grafana) |
| **Alertmanager → n8n** | In-cluster `http://n8n-app.ai-ops.svc.cluster.local:5678/webhook/vmalert` (bypasses ingress) |

Grafana has full **Generic OAuth** via Authentik (`grafana-oauth.configmap.yaml`, `grafana-authentik-oauth` secret, Helm `auth.generic_oauth`). n8n has **none** of that — by design for the automation-first deploy, not because n8n cannot do OAuth in general.

## Why native OAuth/OIDC is not in GitOps

1. **License** — [n8n SSO docs](https://docs.n8n.io/hosting/configuration/environment-variables/sso/) state that single sign-on (OIDC/SAML) is available on **Business and Enterprise** plans. Self-hosted **Community** does not include SSO; env vars such as `N8N_SSO_OIDC_*` exist from v2.18+ but require a paid license to activate.

2. **Never implemented** — No Authentik blueprint, no `n8n-authentik-oauth` SOPS secret, no `N8N_SSO_*` env in `apps/base/n8n/helmrelease.yaml`.

3. **Webhooks must stay open (in-cluster)** — Closed-loop remediation uses unauthenticated webhooks on the cluster Service. UI OAuth at the app layer does not affect that path; ingress-level auth must **exclude** `/webhook/*` if added later.

## Options (homelab)

### A) Keep as-is (current)

- UI: local n8n user + HTTPS ingress.
- Automation: in-cluster webhooks + `$env` secrets (no n8n credential store for GitOps flow).

### B) Authentik **forward auth** on ingress (Community-friendly)

Protect the editor with Authentik Proxy Provider + F5 NGINX `server-snippets` / Policy (`auth_request` to outpost). **Exclude** `/webhook` (and optionally `/rest/oauth2-credential/callback` if using node OAuth).

- Pros: Same IdP as Grafana, no n8n license.
- Cons: Not integrated into n8n user management; separate from n8n “Sign in with OIDC” UI.

### C) Native OIDC (Enterprise/Business license)

When you have a license key:

1. Authentik OAuth2 provider — redirect URI:
   `https://n8n.cluster.f4mily.net/rest/sso/oidc/callback`
2. Discovery endpoint: `https://login.f4mily.net/application/o/n8n/.well-known/openid-configuration` (slug after blueprint).
3. Helm env (see [SSO environment variables](https://docs.n8n.io/hosting/configuration/environment-variables/sso/)):

```yaml
N8N_SSO_MANAGED_BY_ENV: "true"
N8N_SSO_OIDC_LOGIN_ENABLED: "true"
N8N_SSO_OIDC_DISCOVERY_ENDPOINT: https://login.f4mily.net/application/o/n8n/.well-known/openid-configuration
N8N_SSO_OIDC_CLIENT_ID: # from SOPS
N8N_SSO_OIDC_CLIENT_SECRET_FILE: /etc/n8n-sso/client-secret
```

`N8N_EDITOR_BASE_URL` is already set in the HelmRelease for correct callback URLs.

## n8n 2.x upgrade notes (2.21.7)

See [n8n v2.0 breaking changes](https://docs.n8n.io/2-0-breaking-changes/).

| Topic | Homelab choice |
|-------|----------------|
| Task runners | `N8N_RUNNERS_ENABLED=true`, `N8N_RUNNERS_MODE=internal` (single replica; no `n8nio/runners` sidecar) |
| Code node `$env` | `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` (required for GitOps remediation workflow) |
| SQLite | Unchanged on PVC |
| Publish vs activate | Re-import workflow; **publish** active remediation workflow in UI if migration report flags it |

External task runners (`n8nio/runners` sidecar, broker port 5679) are only needed for **external** runner mode or Python Code nodes — not used here.

## References

- Helm: `apps/base/n8n/helmrelease.yaml`
- Grafana pattern: `docs/integrations/grafana-authentik.md`
- GitOps remediation: `docs/integrations/alerting-n8n-gitops-remediation.md`
