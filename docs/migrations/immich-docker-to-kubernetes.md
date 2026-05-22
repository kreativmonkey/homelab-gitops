# Immich: Docker (production) → Kubernetes

Migrate the production Immich stack (Docker Compose on the NAS host) to the
homelab cluster (Flux HelmRelease, CloudNativePG `immich-postgres`, NFS library
PVCs).

**Source reference:** `Migration/Immich/compose.yml` (exported from Dockge).

**Target:** `apps/base/immich/`, `infrastructure/overlays/main/database-clusters/immich-postgres/`.

## Architecture comparison

| Component | Docker (production) | Kubernetes (homelab) |
|-----------|---------------------|----------------------|
| App | `immich_server` — `ghcr.io/immich-app/immich-server:release` | Helm chart `immich` — image tag `v1.119.0` (pin in `helmrelease.yaml`) |
| ML | `immich_machine_learning` | Chart subchart `machine-learning` |
| DB | `immich_postgres` — `ghcr.io/immich-app/postgres:14-vectorchord…` | CNPG `immich-postgres` — `ghcr.io/tensorchord/cloudnative-vectorchord:16.9-0.4.3` |
| Redis | `immich_redis` (Valkey 8) | In-cluster Redis (Bitnami legacy image, **no persistence**) |
| Library | `/mnt/truenas/Media/Bilder` → `/usr/src/app/upload` | PVC `immich-library` → NFS `Media` + `subPath: Bilder` |
| Fotos | `/mnt/truenas/Media/Fotos` → `/fotos` | PVC `immich-fotos` → NFS `Media` + `subPath: Fotos` |
| Ingress | Traefik `immich.f4mily.net` | NGINX `immich.cluster.f4mily.net` (cutover → `immich.f4mily.net`) |
| Power Tools | `immich-power-tools` (optional) | Not deployed on cluster yet |

Photos and videos **do not need to be copied** if the cluster NFS PVs point at the
same TrueNAS export (`192.168.10.94:/mnt/Storagepool/Media`) with the same
`subPath` values (`Bilder`, `Fotos`). Only the **PostgreSQL database** must be
migrated; Redis is ephemeral.

## Prerequisites

- [ ] Production compose stack documented (`Migration/Immich/compose.yml`).
- [ ] Cluster: `kubectl get cluster -n cnpg-system immich-postgres` → Ready.
- [ ] Extensions on target DB (via `Database` CR): `vector`, `cube`, `vchord`, `earthdistance`.
- [ ] NFS PVCs bound: `immich-library`, `immich-fotos` in namespace `immich`.
- [ ] Dev shell: `nix develop` (provides `kubectl`, `pg_restore`, `flux`).
- [ ] Maintenance window (Immich offline for DB export/import).
- [ ] **Version check:** align production Immich tag with cluster `helmrelease.yaml`
  (`server.image.tag`). Production uses `:release`; cluster pins `v1.119.0`.
  Major version skew can break schema restore — note prod version before cutover:

```bash
docker inspect immich_server --format '{{.Config.Image}}'
docker exec immich_server immich-admin version 2>/dev/null || true
```

- [ ] **Vector extension:** production Postgres image ships VectorChord; cluster
  Helm sets `DB_VECTOR_EXTENSION: pgvector` for Immich **v1.119**. After restore,
  verify `\dx` and Immich startup logs. Upgrading to Immich v2+ may require
  `DB_VECTOR_EXTENSION` / chart changes — see
  [Immich: pre-existing Postgres](https://docs.immich.app/administration/postgres-standalone).

## Phase 1 — Stop writes on Docker (production host)

Run on the host where Compose is deployed (paths may differ; adjust `COMPOSE_DIR`):

```bash
COMPOSE_DIR=/path/to/immich   # e.g. Dockge stack directory
cd "$COMPOSE_DIR"

# Load credentials (never commit .env — use Migration/Immich/env.example as template)
set -a && source .env && set +a

# Stop app containers; keep database running for consistent dump
docker compose stop immich-server immich-machine-learning immich-power-tools
```

Optional: confirm DB is reachable:

```bash
docker exec immich_postgres pg_isready -U "${DB_USERNAME:-postgres}"
```

## Phase 2 — Database export from Docker

### Custom format (recommended for `pg_restore`)

```bash
BACKUP_DIR="/backup/immich-migration-$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

docker exec -t immich_postgres pg_dump \
  -U "${DB_USERNAME:-postgres}" \
  -Fc \
  --no-owner \
  --no-acl \
  "${DB_DATABASE_NAME:-immich}" \
  > "${BACKUP_DIR}/immich.dump"
```

Using container names from `Migration/Immich/compose.yml`:

| Variable | Production value (compose) |
|----------|----------------------------|
| Postgres container | `immich_postgres` |
| DB user | `postgres` (from `.env` `DB_USERNAME`) |
| DB name | `immich` |

### Plain SQL (alternative)

```bash
docker exec -t immich_postgres pg_dump \
  -U "${DB_USERNAME:-postgres}" \
  -Fp \
  --no-owner \
  --no-acl \
  "${DB_DATABASE_NAME:-immich}" \
  > "${BACKUP_DIR}/immich.sql"
```

### Verify dump

```bash
# List archive contents (needs pg_restore client, e.g. from nix shell)
pg_restore -l "${BACKUP_DIR}/immich.dump" | head -30

# Size sanity check
ls -lh "${BACKUP_DIR}/immich.dump"
```

### Optional: logical backup via host `pg_dump`

If port `5432` is published to the host (not in default compose — DB is internal only):

```bash
PGPASSWORD="$DB_PASSWORD" pg_dump -h 127.0.0.1 -p 5432 -U "$DB_USERNAME" -Fc immich > "${BACKUP_DIR}/immich.dump"
```

### What not to dump

| Service | Migrate? | Reason |
|---------|----------|--------|
| `immich_redis` | No | Cache / job queue; rebuilt on startup |
| `model-cache` volume | No | ML models re-download |
| `./postgres` data dir | No | Use `pg_dump` instead of copying `PGDATA` (safer across PG 14→16) |
| `/mnt/truenas/Media/...` | No* | *Same NFS export on cluster |

Copy `${BACKUP_DIR}` to a machine with `kubectl` access (workstation, jump host).

## Phase 3 — Prepare Kubernetes target

```bash
kubectl get cluster -n cnpg-system immich-postgres
kubectl get database -n cnpg-system homelab-postgres-immich
kubectl get secret -n immich homelab-postgres-immich
kubectl get pvc -n immich immich-library immich-fotos
```

Confirm extensions (empty or pre-provisioned DB):

```bash
kubectl exec -n cnpg-system immich-postgres-1 -- \
  psql -U postgres -d immich -c '\dx'
```

Suspend Immich so it does not write during restore:

```bash
flux suspend helmrelease -n immich immich
kubectl -n immich scale deployment -l app.kubernetes.io/name=immich --replicas=0 2>/dev/null || true
```

If the cluster already has a **test** Immich DB you want to replace, `pg_restore
--clean` (below) drops objects in the target database. For a completely fresh
cluster, the `Database` CR already created an empty `immich` database owned by
role `immich`.

## Phase 4 — Database import into CNPG

Port-forward the primary:

```bash
kubectl port-forward -n cnpg-system svc/immich-postgres-rw 15432:5432
```

In another terminal (credentials from cluster secret):

```bash
export PGPASSWORD="$(
  kubectl get secret -n immich homelab-postgres-immich \
    -o jsonpath='{.data.password}' | base64 -d
)"
export PGUSER="$(
  kubectl get secret -n immich homelab-postgres-immich \
    -o jsonpath='{.data.username}' | base64 -d
)"

pg_restore \
  -h 127.0.0.1 \
  -p 15432 \
  -U "$PGUSER" \
  -d immich \
  --clean \
  --if-exists \
  --no-owner \
  --no-acl \
  /backup/immich-migration-YYYYMMDD/immich.dump
```

**PG 14 → 16:** use a `pg_restore` client from PostgreSQL 16+ (included in
`nix develop`). Harmless errors about missing roles or extensions often appear;
fix missing extensions with:

```bash
kubectl exec -n cnpg-system immich-postgres-1 -- \
  psql -U postgres -d immich -c '\dx'
```

Post-restore checks:

```bash
kubectl exec -n cnpg-system immich-postgres-1 -- \
  psql -U postgres -d immich -c "SELECT COUNT(*) FROM asset;"
kubectl exec -n cnpg-system immich-postgres-1 -- \
  psql -U postgres -d immich -c "SELECT email FROM users LIMIT 5;"
```

## Phase 5 — Start Immich on cluster

```bash
flux resume helmrelease -n immich immich
flux reconcile helmrelease -n immich immich --force
kubectl -n immich rollout status deployment/immich-server
kubectl -n immich logs deployment/immich-server --tail=80
```

Smoke test (before public DNS):

- https://immich.cluster.f4mily.net — login with migrated users
- Library scan: Admin → Library → Scan (if assets exist on NFS but counts look wrong)

## Phase 6 — DNS cutover

1. Stop Docker stack completely (including Postgres) after successful cluster test:

```bash
cd "$COMPOSE_DIR"
docker compose down
# Or leave DB stopped only after verifying cluster for 24–48h
```

2. Point `immich.f4mily.net` to cluster ingress (Terraform DNS /
   `homelab-infrastructure/dns` — today: `immich` public record; cluster ingress
   host is `immich.cluster.f4mily.net` until you align hosts in
   `apps/overlays/main/cluster-config.yaml` / Ingress).

3. `flux reconcile kustomization apps --with-source`

## Rollback

1. `flux suspend helmrelease -n immich immich`
2. `docker compose up -d` on production host
3. Restore DNS to Docker Traefik target
4. Cluster DB remains for retry; production `./postgres` data untouched if you did not delete it

## Optional: Immich Power Tools

Production runs `immich-power-tools` with API key and DB access. Not part of the
cluster Helm release. Re-deploy separately or omit until Immich on cluster is stable.

## Related docs

- [Phase 1 PostgreSQL (other apps)](phase1-postgres.md)
- [NFS PVC migration](nfs-migration.md)
- [CNPG S3 DR](../disaster-recovery/cnpg-s3-dr.md) — `immich-postgres` backups after cutover
