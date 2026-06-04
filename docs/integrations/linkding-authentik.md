# Linkding ↔ Authentik (OIDC)

Bookmark manager: `https://bookmarks.f4mily.net` — [Linkding OIDC](https://linkding.link/options/#ld_enable_oidc), [Authentik integration](https://goauthentik.io/integrations/).

## GitOps

| Artifact | Purpose |
|----------|---------|
| `apps/base/authentik/blueprints/linkding-oauth.configmap.yaml` | OAuth2 provider + application (`slug: linkding`, `client_id: homelab-linkding`) |
| `apps/base/linkding/linkding-authentik-oauth.secret.yaml` | SOPS: `client-id`, `client-secret` (create with `just linkding-authentik-oauth`) |
| `apps/base/linkding/helmrelease.yaml` | `common.variables.nonSecret.*` + `common.variables.secret.*` for OIDC env vars |

Redirect URI (strict): `https://bookmarks.f4mily.net/oidc/callback/`

Issuer URL: `https://login.f4mily.net/application/o/linkding/`

OIDC endpoints (from discovery — do not guess slug on `/token/`):

| Variable | URL |
|----------|-----|
| `OIDC_OP_AUTHORIZATION_ENDPOINT` | `https://login.f4mily.net/application/o/authorize/` |
| `OIDC_OP_TOKEN_ENDPOINT` | `https://login.f4mily.net/application/o/token/` |
| `OIDC_OP_USER_ENDPOINT` | `https://login.f4mily.net/application/o/userinfo/` |
| `OIDC_OP_JWKS_ENDPOINT` | `https://login.f4mily.net/application/o/linkding/jwks/` |

Wrong token URL (`/application/o/linkding/token/`) returns **405** on POST → Linkding `/oidc/callback/` shows **500**.

## Einrichtung

```bash
# 1. SOPS secret (linkding namespace)
just linkding-authentik-oauth

# 2. Secret in kustomization eintragen (falls noch nicht):
#    apps/base/linkding/kustomization.yaml → linkding-authentik-oauth.secret.yaml

# 3. Commit, push, Flux reconcile
flux reconcile kustomization apps -n flux-system --with-source
flux reconcile helmrelease authentik -n authentik --timeout=10m
flux reconcile helmrelease linkding -n linkding --timeout=5m
```

4. In **Authentik** → Provider **Provider for Linkding** → **Client secret** = Wert aus `linkding-authentik-oauth` (`client-secret`), falls Blueprint mit Platzhalter schon lief.

5. Browser: `https://bookmarks.f4mily.net` → **Login with OIDC**.

## Hinweise

- Linkding verwendet `mozilla-django-oidc` — siehe [Dokumentation](https://mozilla-django-oidc.readthedocs.io/).
- `OIDC_USE_PKCE=True` (default) — PKCE wird automatisch verwendet.
- `OIDC_USERNAME_CLAIM=preferred_username` — nutzt den Authentik Username statt Email als Linkding-Username.
- `encryption_key: null` am Provider — verschlüsselte ID-Tokens (JWE) werden von Linkding nicht unterstützt.
- Superuser vor erstem OIDC-Login via User-Setup anlegen (Email muss mit OIDC-Provider übereinstimmen).
