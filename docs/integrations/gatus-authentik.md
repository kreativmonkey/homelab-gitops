# Gatus ↔ Authentik (OIDC)

Status page: `https://status.cluster.f4mily.net` — [Gatus OIDC](https://github.com/TwiN/gatus#oidc), [Authentik integration](https://integrations.goauthentik.io/monitoring/gatus/).

## GitOps

| Artifact | Purpose |
|----------|---------|
| `apps/base/authentik/blueprints/gatus-oauth.configmap.yaml` | OAuth2 provider + application (`slug: gatus`, `client_id: homelab-gatus`) |
| `apps/base/gatus/gatus-authentik-oauth.secret.yaml` | SOPS: `client-id`, `client-secret` (create with `just gatus-authentik-oauth`) |
| `apps/base/gatus/helmrelease.yaml` | `config.security.oidc` + env `OIDC_CLIENT_*` |

Redirect URI (strict): `https://status.cluster.f4mily.net/authorization-code/callback`

Issuer URL: `https://login.f4mily.net/application/o/gatus/`

## Einrichtung

```bash
# 1. SOPS secret (gatus namespace)
just gatus-authentik-oauth

# 2. Secret in kustomization eintragen (falls noch nicht):
#    apps/base/gatus/kustomization.yaml → gatus-authentik-oauth.secret.yaml

# 3. Commit, push, Flux reconcile
flux reconcile kustomization apps -n flux-system --with-source
flux reconcile helmrelease authentik -n authentik --timeout=10m
flux reconcile helmrelease gatus -n gatus --timeout=5m
```

4. In **Authentik** → Provider **Provider for Gatus** → **Client secret** = Wert aus `gatus-authentik-oauth` (`client-secret`), falls Blueprint mit Platzhalter schon lief.

5. Browser: `https://status.cluster.f4mily.net` → **Login with SSO**.

## Hinweise

- Gatus ersetzt in `config.yaml` Platzhalter via `${OIDC_CLIENT_ID}` / `${OIDC_CLIENT_SECRET}` (Helm setzt die Env-Variablen aus dem Secret).
- `encryption_key: null` am Provider — verschlüsselte ID-Tokens (JWE) werden von Gatus nicht unterstützt.
- Unauthentifizierte Checks (z. B. Blackbox auf `/`) können nach OIDC-Aktivierung Redirect/Login sehen — ggf. Health-Pfad oder internen Service-Check nutzen.
