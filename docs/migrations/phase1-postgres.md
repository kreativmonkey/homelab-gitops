# Phase 1: PostgreSQL apps migration (Docker → Kubernetes)

Migrate **Authentik**, **Paperless-ngx**, and **Immich** to the central CloudNativePG cluster (`homelab-postgres`).

## Prerequisites

- Flux reconciling `clusters/main`
- CNPG cluster healthy: `kubectl get cluster -n cnpg-system homelab-postgres`
- pgAdmin: https://pgadmin.cluster.f4mily.net
- Dev shell: `nix develop`

## 1. Verify databases and secrets

```bash
kubectl get database -A
kubectl get secret -n authentik homelab-postgres-authentik
kubectl get secret -n immich homelab-postgres-immich
kubectl get secret -n paperless-ngx homelab-postgres-paperless
```

## 2. Data export from Docker PostgreSQL

Per app on the Docker host:

```bash
docker exec -t <postgres_container> pg_dump -U <user> -Fc <dbname> > /backup/<app>.dump
```

## 3. Data import into CNPG

Port-forward the primary instance:

```bash
kubectl port-forward -n cnpg-system svc/homelab-postgres-rw 5432:5432
```

Restore (example for Authentik):

```bash
pg_restore -h localhost -U authentik -d authentik --clean --if-exists /backup/authentik.dump
```

Use credentials from the app namespace secret `homelab-postgres-<app>`.

## 4. Immich: vector extension

Immich requires the `vector` extension. Confirm after Database reconcile:

```bash
kubectl exec -n cnpg-system homelab-postgres-1 -- psql -U postgres -d immich -c '\dx'
```

If `vector` is missing, install a CNPG image with pgvector or adjust `infrastructure/overlays/main/database-clusters/cluster.yaml` image.

## 5. Application-specific notes

| App | URL | Notes |
|-----|-----|-------|
| Authentik | https://login.f4mily.net | Set `secret-key` via `just sops-edit apps/base/authentik/authentik-secret-key.secret.yaml` (see `.template`) |
| Immich | https://immich.f4mily.net | Resize `immich-library` PVC; copy library files from Docker volume |
| Paperless | https://paperless.f4mily.net | Copy `media`/`data` volumes; re-run consumer after DB import |

## 6. Cutover

1. Stop Docker compose stack for the app
2. `just validate`
3. Point DNS to cluster ingress (if not already)
4. `flux reconcile kustomization apps --with-source`

## 7. Rollback

Re-enable Docker stack and restore previous DNS. CNPG data remains for retry.
