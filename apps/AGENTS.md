# Purpose

Application workloads deployed to the cluster. `base/<app>/` holds generic manifests/HelmReleases per app; `overlays/main/` holds cluster-specific routes, DB wiring, monitoring overrides.

# Ownership

- Owns: per-app deployment manifests, ingress routing, app-level SOPS secrets, OIDC blueprints wiring, DB-consumer manifests.
- Parent root AGENTS.md owns: global stack, governance, CI, commit rules, caveman, DOX rail.
- CNPG operator + cluster-wide services owned by [[infrastructure]].

# Local Contracts

- One folder per app under `base/<app>/` with its own `kustomization.yaml`.
- New app namespaces include their `default` ServiceAccount with `automountServiceAccountToken: false` beside the Namespace manifest; `infra-base` runs before `apps`.
- Web UIs without native OIDC use an Authentik proxy provider on the embedded outpost. Place their public Ingress in `authentik`, route to `authentik-server`, and allow outpost-to-app traffic with matching egress and ingress NetworkPolicies.
- Standard software → HelmRelease (Flux-managed); raw manifests only when no chart.
- Ingress annotations (every public app):
  - `nginx.org/ssl-redirect: "false"`
  - `nginx.org/redirect-to-https: "true"`
  - `nginx.org/websocket-services` when WebSocket needed
  - upload limit via `nginx.org/client-max-body-size` or `nginx.org/proxy-body-size`
- Hostnames as `host_<app>` in `overlays/main/cluster-config.yaml`; TLS secret injected via Kustomize replacements.
- Secrets SOPS-encrypted; `*.secret.yaml.template` is the unencrypted shape reference. Never commit plaintext secret values.
- DB consumer: app gets dedicated CNPG `Cluster` in `infrastructure/overlays/main/database-clusters/<app>/`; credential secret in `overlays/main/db-secrets/`; wire via `valuesFrom`.
- External MCP agents in `base/ai-agents/` receive cluster-wide read access. Any operational exception requires an explicitly approved namespace RoleBinding. Hermes has a separate CNPG backup role in `cnpg-system`.
- Hister uses the shared CNPG cluster. Its ESO credential copy is defined in `overlays/main/hister-db-secret/`. The app receives the copy through Env and needs a pod rollout after a DB password change. Follow the ordered DB-login and app-switch steps in `docs/proposals/eso-generated-secrets.md`.
- Phase 3 DB credential copies use `overlays/main/eso-db-secrets/`. Each app namespace has its own Store identity. Confirm DB login with the new value before switching each app's Secret references.
- Outline reads its Valkey username and password from `outline-valkey-eso`. The namespace-local Store also serves its database credential.
- SearXNG reads `SEARXNG_SECRET` from the ESO copy `searxng-secret-eso`. The ESO reader may get only the active versioned source. Update the Pod template's `homelab.f4mily.net/secret-source` annotation after accepting the new app copy to roll the Pods declaratively. Follow the rotation and recovery procedure in `docs/proposals/eso-generated-secrets.md`.
- Nextcloud HaRP manages ClusterIP ExApps through a Role in `nextcloud-exapps`. Treat that namespace as writable by HaRP. Keep unrelated Secrets and privileged ServiceAccounts outside it.
- OIDC/Authentik onboarding: do NOT auto-enable. Ask user first. Blueprint format + checklist in root AGENTS.md `# OIDC / Authentik Blueprint Onboarding`.
- Backup monitoring treats Velero `PartiallyFailed` as failure and alerts when Velero metrics or successful timestamps are absent. Keep node-exporter CSI `globalmount` metrics visible so read-only iSCSI filesystems remain alertable.
- The CronJob watchdog clears superseded failures once the CronJob reports a later success. Keep failed Jobs under the CronJob's configured history limit for diagnosis. See `docs/runbooks/job-watchdog.md`.
- Forgejo Runner uses a Unix-only Docker API in a shared `emptyDir` mounted only by the runner and DinD. Keep job socket mounting disabled (`container.docker_host: "-"`). The DinD startup probe gates runner startup.
- Homepage cluster mode discovers annotated Ingresses. Annotate only Ingresses with HTTP paths (minions, not pathless NGINX masters); its discovery fails globally otherwise. Keep its dedicated ServiceAccount, projected token, and read-only ClusterRole/Binding aligned with `kubernetes.yaml`; never restore a static ServiceAccount token Secret.

# Work Guidance

- Web-search latest official app docs before adding/upgrading.
- Prefer Kustomize base/overlay to avoid duplication.
- Comment non-obvious patches (WebSocket, resource limits) inline in YAML.

# Verification

- `just validate` locally before PR; `just validate-full` for workload changes.

# Child DOX Index

- `base/ainsel/AGENTS.md` — Ainsel Helm chart, public PKCE client, external CNPG, API exposure and runtime verification.
- Other per-app folders inherit this contract.
