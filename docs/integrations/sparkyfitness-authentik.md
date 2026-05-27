# SparkyFitness login via Authentik

SparkyFitness uses **Better Auth SSO** (OpenID Connect) against Authentik at `https://login.f4mily.net` (application slug **`sparkyfitness`**).

GitOps sets server env via Helm (`apps/base/sparkyfitness/helmrelease.yaml`) and SOPS secret `sparkyfitness-app-values` (`SPARKY_FITNESS_OIDC_CLIENT_ID` / `CLIENT_SECRET`).

## Checklist (SparkyFitness / Helm)

| Setting | GitOps value |
|---------|----------------|
| Issuer URL | `https://login.f4mily.net/application/o/sparkyfitness/` |
| Client ID / secret | `sparkyfitness-app-values` → Helm `valuesFrom` |
| Scope | `openid profile email` ([upstream docs](https://codewithcj.github.io/SparkyFitness/administration/oauth-authentication)) |
| Provider slug / name | `authentik` / `Authentik` |
| Public frontend URL | `https://fitness.f4mily.net` (`config.frontendUrl`) |
| OIDC logo | jsDelivr Authentik icon (`config.oidc.logoUrl`) |
| Auto-register | `true` |
| Email/password login | disabled (`disableEmailLogin`, `forceEmailLogin: false`) |
| Auto-redirect to IdP | `true` |

## Checklist (Authentik admin)

1. **Application** slug `sparkyfitness`, provider type OAuth2/OIDC.
2. **Redirect URI** (strict) — must match Better Auth, not the legacy `oidc-callback` path from older docs:

   ```text
   https://fitness.f4mily.net/api/auth/sso/callback/authentik
   ```

   (`authentik` = `config.oidc.providerSlug` in Helm.)

3. **Scopes / property mappings**: `openid`, `profile`, `email` (same as Grafana blueprint pattern).
4. **Client ID** and **client secret** match `sparkyfitness-app-values` in the cluster.
5. **Signing**: RS256 for ID token (SparkyFitness defaults; Authentik default).

## Verify

```bash
# Discovery (from a host that reaches login.f4mily.net)
curl -sS https://login.f4mily.net/application/o/sparkyfitness/.well-known/openid-configuration | jq .issuer

# Server env (after Flux reconcile)
kubectl -n sparkyfitness exec deploy/sparkyfitness-server -- env | grep SPARKY_FITNESS_OIDC
```

1. Open https://fitness.f4mily.net → should redirect to Authentik.
2. After login, return to SparkyFitness with a session.

## Privacy policy (admin UI)

The [SparkyFitness OAuth guide](https://codewithcj.github.io/SparkyFitness/administration/oauth-authentication) lists **Privacy Policy** as an admin setting. That is configured in the app UI (or DB), not via the Helm chart env vars.

## Break-glass

If OIDC is misconfigured, temporarily set in Helm `config.forceEmailLogin: true` and `config.disableEmailLogin: false`, reconcile, and use a local account — then fix Authentik redirect URI and revert.

## References

- [SparkyFitness OAuth documentation](https://codewithcj.github.io/SparkyFitness/administration/oauth-authentication)
- [SparkyFitness environment variables (OIDC)](https://github.com/CodeWithCJ/SparkyFitness/blob/main/docs/content/1.install/6.environment-variables.md)
- Helm: `apps/base/sparkyfitness/helmrelease.yaml`
