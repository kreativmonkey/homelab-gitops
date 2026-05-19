# Phase 1: PostgreSQL apps migration (Docker → Kubernetes)

Migrate **Authentik** and **Paperless-ngx** to the central CloudNativePG cluster (`homelab-postgres`). **Immich** uses a dedicated cluster (`immich-postgres`) with the VectorChord image — see `infrastructure/overlays/main/database-clusters/immich-postgres/`.

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

## 4. Immich: VectorChord (dedicated cluster)

Immich v1.119+ requires **VectorChord** (`vchord`) and `earthdistance` on PostgreSQL 16+, not the stock CNPG image on `homelab-postgres`. The homelab is still in a **test phase**: there is no production Immich database to migrate. Flux provisions an empty `immich` database; photos live on **NFS** (`immich-library` / `immich-fotos` PVCs) and Immich will re-index the library on first run.

Sections 2–3 (Docker `pg_dump` / `pg_restore`) do **not** apply to Immich.

After Flux reconciles `immich-postgres` and the `Database` CR `homelab-postgres-immich`:

```bash
kubectl get cluster -n cnpg-system immich-postgres
kubectl exec -n cnpg-system immich-postgres-1 -- psql -U postgres -d immich -c '\dx'
```

Expect `cube`, `vchord`, and `earthdistance`. If the cluster was recreated, delete any stale `immich` database on `homelab-postgres` manually only when you no longer need it for experiments.

## 5. Application-specific notes

| App | URL | Notes |
|-----|-----|-------|
| Authentik | https://login.f4mily.net | Set `secret-key` via `just sops-edit apps/base/authentik/authentik-secret-key.secret.yaml` (see `.template`) |
| Immich | https://immich.f4mily.net | Library on NFS (`subPath` Bilder/Fotos); empty DB is fine — run admin setup / library scan after deploy |
| Paperless | https://paperless.f4mily.net | Copy `media`/`data` volumes; re-run consumer after DB import |

## 6. Cutover

1. Stop Docker compose stack for the app
2. `just validate`
3. Point DNS to cluster ingress (if not already)
4. `flux reconcile kustomization apps --with-source`

## 7. Rollback

Re-enable Docker stack and restore previous DNS. CNPG data remains for retry.
