# Application Migration Guide

General patterns for moving applications from Docker/live hosts to the
homelab Kubernetes cluster. Focus on data transfer — not app-specific config.

> **Before you start:** check `docs/learnings/` for known pitfalls.

---

## Table of Contents

- [1. Architecture Overview](#1-architecture-overview)
- [2. Database Migration (PostgreSQL)](#2-database-migration-postgresql)
- [3. PVC / NFS Data Migration](#3-pvc--nfs-data-migration)
- [4. S3 Bucket (Garage)](#4-s3-bucket-garage)
- [5. First-Time Deploy (Fresh App)](#5-first-time-deploy-fresh-app)
- [6. Cutover & DNS](#6-cutover--dns)
- [7. Troubleshooting](#7-troubleshooting)

---

## 1. Architecture Overview

| Component | Cluster (Target) | Old (Docker) |
|-----------|------------------|--------------|
| Database | **CloudNativePG** `homelab-postgres` (shared, per-app DB/role) | Standalone Postgres container |
| Persistent data | **NFS** (`nfs-media-static`, RWX) for media/large files | Host bind mount |
| Block data | **TrueNAS iSCSI** (`truenas-iscsi`, RWO) for app config / DBs | Docker volume |
| Object storage | **Garage S3** (Nextcloud only) | Local filesystem |
| Secrets | **SOPS**-encrypted `.secret.yaml` in Git | `.env` file |
| Ingress | **NGINX** + wildcard TLS | Traefik / Caddy |

**Two storage classes, each with a different migration approach:**

```
nfs-media-static (RWX)   → direct rsync to NAS, PVC binds automatically
truenas-iscsi    (RWO)   → Job + kubectl cp, or rsync before cutover
```

---

## 2. Database Migration (PostgreSQL)

### 2.1 Export from Docker

#### Option A: running container

```bash
docker exec <postgres_container> pg_dump \
  -U <user> \
  -Fc \
  --no-owner \
  --no-acl \
  <dbname> \
  > /backup/<app>.dump
```

**Do NOT use `docker exec -t`** — a TTY corrupts binary `-Fc` dumps
(`pg_restore` segfault / EOF).

#### Option B: from PGDATA directory (migration export)

```bash
PGDATA=/path/to/Migration/<app>/database
OUT=/tmp/<app>.dump

docker run --rm \
  -v "$PGDATA:/var/lib/postgresql/data:ro" \
  -e PGDATA=/var/lib/postgresql/data \
  postgres:16 \
  sh -c 'pg_ctl -D /var/lib/postgresql/data -o "-c listen_addresses=" start -w && \
    pg_dump -U <user> -Fc --no-owner --no-acl <dbname> > /tmp/dump && \
    pg_ctl -D /var/lib/postgresql/data stop -m fast' \
  && docker cp "$(docker ps -lq):/tmp/dump" "$OUT"
```

#### Option C: plain SQL (safest cross-version)

```bash
docker exec <postgres_container> pg_dump \
  -U <user> -Fp --no-owner --no-acl <dbname> \
  > /backup/<app>.sql
```

Plain SQL avoids `pg_restore` segfaults when source/target PG versions
or extension sets differ. Slower for large DBs but more robust.

### 2.2 Import into CNPG

#### Prerequisites

```bash
# Database CR deployed?
kubectl get database -n cnpg-system homelab-postgres-<app>

# Credentials
kubectl get secret -n <ns> homelab-postgres-<app> \
  -o jsonpath='{.data.password}' | base64 -d
```

#### Method A: port-forward (workstation)

```bash
kubectl port-forward -n cnpg-system svc/homelab-postgres-rw 5432:5432 &
PGPASSWORD="$(kubectl get secret -n <ns> homelab-postgres-<app> -o jsonpath='{.data.password}' | base64 -d)"

pg_restore -h localhost -U <app> -d <app> \
  --no-owner --no-acl \
  /backup/<app>.dump
```

#### Method B: NodePort (if port-forward not reachable)

```bash
NODE_IP=192.168.10.41   # any control-plane
pg_restore -h "$NODE_IP" -p 30433 -U <app> -d <app> \
  --no-owner --no-acl \
  /backup/<app>.dump
```

Set `--clean --if-exists` if replacing an existing test DB.

### 2.3 What NOT to migrate

| Component | Reason |
|-----------|--------|
| Redis / Valkey | Ephemeral cache / job queue — rebuilt on startup |
| Postgres data dir | Use `pg_dump` — safer across PG version upgrades |
| SQLite files | Convert to Postgres or re-create |

### 2.4 Verify

```bash
PGPASSWORD="..." psql -h localhost -U <app> -d <app> \
  -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';"
```

For Authentik specifically:

```bash
PGPASSWORD="..." psql -h localhost -U authentik -d authentik \
  -c "SELECT COUNT(*) FROM authentik_core_user;"
```

---

## 3. PVC / NFS Data Migration

### 3.1 NFS (RWX) — direct re-use

Static NFS PVs point at TrueNAS export paths. **Existing files on the
NAS are reused automatically** once the PVC binds. No copy needed if
the app already reads from the same NAS share.

```yaml
# infrastructure/base/storage/pv-nfs.yaml
spec:
  nfs:
    server: 192.168.10.94
    path: /mnt/Storagepool/Media
  mountOptions: [nfsvers=4.2, hard]
```

App PVC references a `subPath`:

```yaml
volumeMounts:
  - name: media
    mountPath: /app/data
    subPath: docker/<app>/data
```

#### To populate NFS data (migration from old host)

```bash
# Direct rsync to NAS (if old host has NFS or SSH access)
rsync -avH /old/path/<app>/ /mnt/truenas/Media/docker/<app>/

# OR: copy via Job (when old data is on a different filesystem)
# See scripts/migrations/ for examples
```

### 3.2 iSCSI (RWO) — data must be copied

iSCSI PVCs are provisioned dynamically by democratic-csi on TrueNAS.
First-time data population requires a Job.

#### Method A: Job with kubectl cp

Scaling the app down first prevents writes during migration.

```yaml
# Example one-shot data-migrate Job (apply manually, not in kustomization)
apiVersion: batch/v1
kind: Job
metadata:
  name: <app>-data-migrate
  namespace: <ns>
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: busybox:1.37
          command: ["sleep", "3600"]   # keep running for kubectl cp
          volumeMounts:
            - name: data
              mountPath: /mnt
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: <app>-data
```

Usage:

```bash
kubectl apply -f <job-file>
POD=$(kubectl get pod -n <ns> -l job-name=<app>-data-migrate -o jsonpath='{.items[0].metadata.name}')

# Copy data into the PVC
tar -czf /tmp/<app>-data.tar.gz -C /path/to/old/data .
kubectl cp /tmp/<app>-data.tar.gz <ns>/$POD:/tmp/
kubectl exec -n <ns> $POD -- sh -c 'tar -xzf /tmp/<app>-data.tar.gz -C /mnt'

# Delete job
kubectl delete job -n <ns> <app>-data-migrate
```

For large files > 100MB, split the tarball:

```bash
split -b 100M /tmp/<app>-data.tar.gz /tmp/<app>-part-
for f in /tmp/<app>-part-*; do kubectl cp "$f" <ns>/$POD:/tmp/; done
kubectl exec -n <ns> $POD -- sh -c 'cat /tmp/<app>-part-* > /tmp/data.tar.gz && tar -xzf /tmp/data.tar.gz -C /mnt'
```

#### Method B: rsync via direct NAS mount

If the old host can mount the TrueNAS iSCSI target or NFS path:

```bash
rsync -avH --delete /old/data/ /mnt/truenas/<path>/
```

### 3.3 Fixing Permissions

Application containers run as non-root (`runAsUser: 1000` etc.).
Files copied via Job run as root (UID 0) and may need ownership fixed:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: <app>-fix-perms
  namespace: <ns>
spec:
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: fix
          image: busybox:1.37
          securityContext:
            runAsUser: 0
          command:
            - sh
            - -c
            - |
              chown -R 1000:1000 /mnt
              chmod -R u+rwX,g+rwX /mnt
          volumeMounts:
            - name: data
              mountPath: /mnt
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: <app>-data
```

### 3.4 Migrating PVC StorageClass

PVCs have **immutable** `storageClassName`, `accessModes`, and
`volumeName`. To switch from one storage class to another:

```bash
# 1. Suspend the HelmRelease / scale down
flux suspend helmrelease -n <ns> <app>

# 2. Delete old PVC (data lost if not backed up!)
kubectl delete pvc -n <ns> <old-pvc> --wait=false

# 3. If stuck in Terminating with finalizers:
kubectl patch pvc -n <ns> <old-pvc> \
  -p '{"metadata":{"finalizers":null}}' --type=merge

# 4. Update the manifest in Git with new storageClassName
# Flux recreates the PVC with the new class

# 5. Resume
flux resume helmrelease -n <ns> <app>
```

---

## 4. S3 Bucket (Garage)

Used for **Nextcloud Primary Storage** (garage `nextcloud` bucket).

### 4.1 S3 configuration

```php
'objectstore' => [
    'class' => '\OC\Files\ObjectStore\S3',
    'arguments' => [
        'bucket' => '<bucket>',
        'region' => 'garage',
        'hostname' => '192.168.10.94',
        'port' => '30188',
        'storageClass' => 'STANDARD',
        'objectPrefix' => 'urn:oid:',
        'autocreate' => false,
        'use_ssl' => false,
        'use_path_style' => true,
        'legacy_auth' => false,
        'key' => '...',
        'secret' => '...',
    ],
],
```

### 4.2 Uploading files

S3 stores each file as `urn:oid:{fileid}` — the fileid comes from
the database `oc_filecache` table. **Never** delete `oc_filecache`
when using S3 primary storage — metadata exists only in the DB.

```bash
# Using s3cmd
s3cmd --host=192.168.10.94:30188 \
  --host-bucket=192.168.10.94:30188 \
  --access_key=... --secret_key=... \
  --no-ssl put <file> s3://<bucket>/urn:oid:<fileid>
```

### 4.3 DB migration for S3

After file upload, update storage references in the database:

```sql
-- Rename home storages to object storages
UPDATE oc_storages SET id = 'object::user:<user>' WHERE numeric_id = <id>;
UPDATE oc_storages SET id = 'object::store:amazon::<bucket>' WHERE <condition>;
UPDATE oc_mounts SET mount_provider_class = 'OC\Files\Mount\ObjectHomeMountProvider'
WHERE mount_provider_class LIKE '%HomeMountPoint%';
```

### 4.4 S3 → Local rollback

```sql
UPDATE oc_storages SET id = CONCAT('home::', SUBSTRING(id FROM 14))
  WHERE id LIKE 'object::user:%';
UPDATE oc_storages SET id = 'local::/var/www/html/data/'
  WHERE id = 'object::store:amazon::<bucket>';
UPDATE oc_mounts SET mount_provider_class = 'OC\Files\Mount\HomeMountPoint'
  WHERE mount_provider_class = 'OC\Files\Mount\ObjectHomeMountProvider';
```

---

## 5. First-Time Deploy (Fresh App)

No migration needed — just ensure prerequisites are met:

```bash
# 1. Database (if app needs Postgres)
kubectl get database -n cnpg-system homelab-postgres-<app>

# 2. PVCs
kubectl get pvc -n <ns>

# 3. Secrets
# Template → fill values → SOPS encrypt
cp apps/base/<app>/<secret>.yaml{.template,}
sops -e -i apps/base/<app>/<secret>.yaml

# 4. DNS
# Add host_<app> to apps/overlays/main/cluster-config.yaml
# Add replacement block in apps/overlays/main/kustomization.yaml

# 5. Validate
just validate

# 6. Merge PR → Flux sync
flux reconcile kustomization apps --with-source
```

---

## 6. Cutover & DNS

### Step-by-step cutover

1. **Stop old stack** — prevent writes during migration
2. **Export DB** — `pg_dump` (see §2)
3. **Copy files** — rsync or Job (see §3)
4. **PR manifests** — app base + overlay (ingress, secrets)
5. **Merge PR** — GitHub → Flux syncs
6. **Verify** — pod running, ingress reachable
7. **Update DNS** — point hostname to cluster ingress (`192.168.10.245`)

### DNS management

```bash
# DNS lives in sibling repo (homelab-infrastructure/dns/servers.tf)
cd ../homelab-infrastructure
nix develop .#talos
cd talos
tofu init && tofu plan   # check DNS changes
tofu apply               # apply
```

### Verification checklist

```bash
# Pod status
kubectl get pods -n <ns> -w

# Ingress reachable
curl -skI https://<app>.f4mily.net

# Database access
PGPASSWORD="..." psql -h homelab-postgres-rw.cnpg-system.svc -U <app> -d <app> -c "\dt"

# Flux health
flux get kustomizations
flux get helmreleases -n <ns>
kubectl get events -n <ns> --sort-by='.lastTimestamp' | tail -10
```

---

## 7. Troubleshooting

### 7.1 pg_restore: [archiver] could not open input file

Cause: `docker exec -t` corrupted the binary custom-format dump.
**Fix:** re-export without `-t`, or use plain SQL (`-Fp`).

### 7.2 pg_restore segfault / EOF

Cause: PG version mismatch or corrupted dump.
**Fix:** use plain SQL (`-Fp`) instead of custom format (`-Fc`).

### 7.3 PVC stuck in Terminating

```bash
kubectl patch pvc -n <ns> <pvc> \
  -p '{"metadata":{"finalizers":null}}' --type=merge
kubectl delete pvc -n <ns> <pvc> --force --grace-period=0
```

### 7.4 s6-svscan: unable to open .s6-svscan/lock

Cause: Forgejo image drops privileges via s6. Forcing `runAsUser`
causes a permission conflict.
**Fix:** remove `runAsUser`/`runAsGroup` from the Deployment spec.

### 7.5 CNPG: "role <app> does not exist" on restore

Cause: the dump references the old Docker role OID.
**Fix:** use `pg_restore --no-owner --role=<app>`.

### 7.6 CNPG: extension missing (vector, vchord, ...)

```bash
kubectl exec -n cnpg-system <cluster>-1 -- \
  psql -U postgres -d <db> -c 'CREATE EXTENSION IF NOT EXISTS vector;'
```

Or ensure the `Database` CR lists required extensions.

### 7.7 HelmRelease: "spec is immutable" on PVC change

Cause: PVC fields `storageClassName`, `accessModes` are immutable.
**Fix:** delete the PVC in-cluster, let Flux recreate (§3.4).

### 7.8 OIDC / Authentik: "Invalid redirect URI"

Ensure the redirect URI in the Authentik blueprint matches the actual
ingress URL exactly (including trailing slash and path).

```yaml
redirect_uris:
  - matching_mode: strict
    url: https://<app>.f4mily.net/<callback-path>
```

### 7.9 Nextcloud S3: "File not found" / blank pages

Cause: `oc_filecache` was deleted or storage IDs are wrong.
S3 stores files as `urn:oid:{fileid}` — the file cache is the only
source of filename→fileid mapping.
**Fix:** restore `oc_filecache` from DB backup. Never run
`occ files:scan --all` after deleting filecache on S3.

### 7.10 Large file upload fails (nginx body size)

```yaml
nginx.org/client-max-body-size: "0"       # unlimited
# OR
nginx.org/proxy-body-size: "500m"         # limit in megabytes
```

Add annotation to the app's Ingress.
