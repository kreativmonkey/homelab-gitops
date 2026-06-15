# Purpose

Application workloads deployed to the cluster. `base/<app>/` holds generic manifests/HelmReleases per app; `overlays/main/` holds cluster-specific routes, DB wiring, monitoring overrides.

# Ownership

- Owns: per-app deployment manifests, ingress routing, app-level SOPS secrets, OIDC blueprints wiring, DB-consumer manifests.
- Parent root AGENTS.md owns: global stack, governance, CI, commit rules, caveman, DOX rail.
- CNPG operator + cluster-wide services owned by [[infrastructure]].

# Local Contracts

- One folder per app under `base/<app>/` with its own `kustomization.yaml`.
- Standard software → HelmRelease (Flux-managed); raw manifests only when no chart.
- Ingress annotations (every public app):
  - `nginx.org/ssl-redirect: "false"`
  - `nginx.org/redirect-to-https: "true"`
  - `nginx.org/websocket-services` when WebSocket needed
  - upload limit via `nginx.org/client-max-body-size` or `nginx.org/proxy-body-size`
- Hostnames as `host_<app>` in `overlays/main/cluster-config.yaml`; TLS secret injected via Kustomize replacements.
- Secrets SOPS-encrypted; `*.secret.yaml.template` is the unencrypted shape reference. Never commit plaintext secret values.
- DB consumer: app gets dedicated CNPG `Cluster` in `infrastructure/overlays/main/database-clusters/<app>/`; credential secret in `overlays/main/db-secrets/`; wire via `valuesFrom`.
- OIDC/Authentik onboarding: do NOT auto-enable. Ask user first. Blueprint format + checklist in root AGENTS.md `# OIDC / Authentik Blueprint Onboarding`.

# Work Guidance

- Web-search latest official app docs before adding/upgrading.
- Prefer Kustomize base/overlay to avoid duplication.
- Comment non-obvious patches (WebSocket, resource limits) inline in YAML.

# Verification

- `just fmt && just lint && just test` locally before PR.

# Child DOX Index

No child AGENTS.md. Per-app folders inherit this contract.
