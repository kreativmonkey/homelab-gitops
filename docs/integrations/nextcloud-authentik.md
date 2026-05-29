# Nextcloud login via Authentik

Nextcloud uses the **OpenID Connect user backend** app (`user_oidc`) against Authentik at `https://login.f4mily.net`.

## Prerequisites

1. Nextcloud reachable at `https://nextcloud.cluster.f4mily.net` (pod Ready, `status.php` 200).
2. SOPS secret `nextcloud-authentik-oauth` in the `nextcloud` namespace (see below).
3. Authentik **Application + OAuth2 provider** (slug **`nextcloud`**) — not in GitOps blueprints (Authentik DB is authoritative).

## 1. OAuth secret (GitOps)

From `gitops-homelab/` with `SOPS_AGE_KEY_FILE` set:

```bash
just nextcloud-authentik-oauth
```

Creates `apps/base/nextcloud/nextcloud-authentik-oauth.secret.yaml` (`client-id`: `homelab-nextcloud`, random `client-secret`).

Commit, push, Flux reconcile.

## 2. Authentik provider (admin UI)

Create **Applications → Application** with provider **OAuth2/OIDC**:

| Field | Value |
|-------|--------|
| Application slug | `nextcloud` |
| Provider name | Provider for Nextcloud |
| Client type | Confidential |
| Client ID | `homelab-nextcloud` (same as SOPS `client-id`) |
| Client secret | Same as SOPS `client-secret` |
| Redirect URIs (strict) | `https://nextcloud.cluster.f4mily.net/apps/user_oidc/code` |

If Nextcloud still sends `/index.php/apps/user_oidc/code`, pretty URLs are not active (wrong `overwrite.cli.url` or stale `.htaccess` on NFS). GitOps runs `occ maintenance:update:htaccess` on deploy; you can also add the `index.php` URI in Authentik as fallback.
| Signing key | authentik Self-signed Certificate (default) |
| Subject mode | Based on the User's UUID |
| Scopes | `openid`, `profile`, `email` |

Discovery URL (for Nextcloud UI / `occ`):

```text
https://login.f4mily.net/application/o/nextcloud/.well-known/openid-configuration
```

Optional: [Authentik Nextcloud integration](https://docs.goauthentik.io/integrations/services/nextcloud/) (quota/groups scope mapping).

## 3. GitOps / cluster (automatic)

Helm init `occ-oidc-setup` (see `apps/base/nextcloud/helmrelease.yaml`):

- Enables app `user_oidc`
- Sets `allow_local_remote_servers` (cluster → Authentik)
- Registers provider `authentik` via `occ user_oidc:provider` when the SOPS secret exists
- Sets `allow_multiple_user_backends=0` → login redirects to Authentik (no local form)

After reconcile:

```bash
kubectl -n nextcloud exec deploy/nextcloud -- php occ user_oidc:provider authentik
kubectl -n nextcloud exec deploy/nextcloud -- php occ config:app:get user_oidc allow_multiple_user_backends
```

## Verify

1. Open https://nextcloud.cluster.f4mily.net → redirect to Authentik.
2. Log in with an Authentik user → Nextcloud dashboard (user provisioned on first login).

## Break-glass (local admin)

If OIDC is misconfigured:

```text
https://nextcloud.cluster.f4mily.net/login?direct=1
```

Uses the **local** admin from `nextcloud-admin` (created on first `occ maintenance:install`).  
Re-enable SSO later: `occ config:app:set --value=0 user_oidc allow_multiple_user_backends`.

## Notes

- **No local account required** for normal use — Authentik users are provisioned on first OIDC login.
- Server-side encryption in Nextcloud is **incompatible** with OIDC; use LDAP if you need it ([Authentik docs](https://docs.goauthentik.io/integrations/services/nextcloud/)).
- Do not create a personal Nextcloud account on the login form unless testing; use Authentik instead.

## References

- [Authentik — Nextcloud](https://docs.goauthentik.io/integrations/services/nextcloud/)
- [user_oidc app](https://github.com/nextcloud/user_oidc)
- Helm: `apps/base/nextcloud/helmrelease.yaml`
