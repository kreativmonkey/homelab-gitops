# Grafana login via Authentik

Grafana uses **Generic OAuth** against Authentik at `https://login.f4mily.net` (application slug **`grafana`**).

## One-time setup

### 1. Create the OAuth secret (Git + cluster)

From `gitops-homelab/` with `SOPS_AGE_KEY_FILE` set:

```bash
just grafana-authentik-oauth
```

This creates `apps/base/monitoring/notifications/grafana-authentik-oauth.secret.yaml` with:

- `client-id`: `homelab-grafana`
- `client-secret`: random value

Commit the encrypted secret, push, and let Flux reconcile.

### 2. Authentik provider

Flux applies blueprint `authentik-grafana-blueprint` (ConfigMap). After reconcile:

1. Open **Authentik Admin** → **Applications** → **Grafana** → **Provider**
2. Set **Client secret** to the same value as in the SOPS secret (`client-secret` key)
3. Confirm redirect URI: `https://grafana.cluster.f4mily.net/login/generic_oauth`
4. Confirm scopes include **OpenID entitlements** (blueprint adds `entitlements` mapping)

### 3. Entitlements (Grafana roles)

In Authentik, on the **Grafana** application → **Application entitlements**, create:

| Entitlement name   | Grafana role (via `role_attribute_path`) |
|--------------------|------------------------------------------|
| `Grafana Admins`   | Admin                                    |
| `Grafana Editors`  | Editor                                   |
| (none)             | Viewer (default)                         |

Bind users or groups to these entitlements.

### 4. Verify

1. Open https://grafana.cluster.f4mily.net
2. Click **Sign in with Authentik**
3. After login, check **Administration → Users** for the correct org role

## Break-glass login

Local Grafana admin (`grafana-admin-credentials` secret) remains enabled. Use it if Authentik or OAuth is misconfigured.

## Optional

- **Auto-login only via Authentik:** set `GF_AUTH_OAUTH_AUTO_LOGIN=true` in the Grafana Helm values.
- **Hide local login form:** set `auth.disable_login_form: true` in `grafana.ini` (only after OAuth works).

## References

- [Authentik Grafana integration](https://integrations.goauthentik.io/monitoring/grafana/)
- Helm values: `apps/base/monitoring/vm-k8s-stack/helmrelease.yaml`
- Blueprint: `apps/base/authentik/blueprints/grafana-oauth.configmap.yaml`
