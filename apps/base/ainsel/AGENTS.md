# Purpose

Ainsel agent platform: upstream Helm chart, UI, hub, MCP and namespaced operators.

# Ownership

- Owns Ainsel HelmRelease, pinned chart source, namespace, ingress and encrypted runtime credentials.
- Authentik blueprint lives in `../authentik/blueprints/ainsel-oauth.configmap.yaml`.
- Database and credentials live in `../../overlays/main/{databases,db-secrets}/` and infrastructure CNPG managed roles.

# Local Contracts

- HelmRelease depends on Authentik readiness; verify issuer discovery separately because blueprint discovery can run on an old worker during rollout (see `../../../docs/learnings/authentik-blueprint-worker-rollout.md`).
- Authentik public client `homelab-ainsel` uses authorization code + PKCE; never put client secrets in browser configuration.
- Authentik application access requires `Admin` or `authentik Admins`. Ainsel admin rights remain database-managed.
- External PostgreSQL uses central CNPG; do not enable bundled PostgreSQL.
- Publish only `/api/v1` (including WebSocket), `/mcp`, OAuth protected-resource metadata and frontend. `/api/internal` must stay inaccessible through frontend proxy.
- Cluster NetworkPolicy baseline owns traffic rules; upstream chart policies stay disabled.
- Pin chart commit and component image tags to tested builds. Connector operator stays namespace-scoped.

# Work Guidance

- Keep host/TLS replacements in the main overlay aligned with ingress.
- Keep internal validation and skill catalogue tokens distinct and SOPS-encrypted in `ainsel-runtime`. Inject with `extraEnv[].valueFrom.secretKeyRef`; leave chart `auth.internalValidateSecret` / `auth.skillsMcpToken` values empty so tokens never become literal platform Pod environment values.

# Verification

- `just validate-full` plus explicit upstream `helm template` and `kubeconform` (repository renderer skips GitRepository charts).
- Verify controller rollout, PostgreSQL, HTTPS, PKCE login, unauthenticated API rejection and internal-route rejection.

# Child DOX Index
