# CNPG Backup & Disaster Recovery (S3 / Barman)

PostgreSQL clusters (`homelab-postgres`, `immich-postgres`) use **Barman Cloud** via `barmanObjectStore` for continuous WAL archiving and scheduled base backups to S3-compatible storage (Garage on TrueNAS at `http://192.168.10.94:30188` (S3 API; `:30186` is the web UI only), same endpoint as Velero).

## Prerequisites

1. S3 bucket `cnpg-backups` exists on the object store (create manually before first reconcile).
2. S3 credentials in `cnpg-barman-s3-credentials` (SOPS or ExternalSecret — never plaintext in Git).
3. CNPG operator and cluster healthy in normal operation (`infrastructure/overlays/main`).

## Normal operation (backup)

Flux path: `./infrastructure/overlays/main`

- WAL archived continuously (`archive_timeout` default ~5 min RPO)
- `ScheduledBackup` `homelab-postgres-daily` and `immich-postgres-daily` at 02:30 UTC
- Retention: `30d` on object store

Verify:

```bash
kubectl get cluster -n cnpg-system homelab-postgres
kubectl get scheduledbackup -n cnpg-system
kubectl get backup -n cnpg-system
```

## Disaster recovery (full cluster rebuild)

> **Full runbook** (Talos reset, Flux bootstrap, pitfalls): [README.md](README.md)

**Flux** reconciles from `https://github.com/kreativmonkey/homelab-gitops` branch `main`. Push DR commits to **GitHub** before `flux reconcile source git flux-system`.

### 1. Suspend app reconciliation (recommended)

```bash
flux suspend kustomization apps -n flux-system
```

### 2. Switch infrastructure overlay to DR

Edit [`clusters/main/infrastructure.yaml`](../../clusters/main/infrastructure.yaml) — change `infra-main` path:

```yaml
path: ./infrastructure/overlays/disaster-recovery
```

Commit/push or patch locally, then reconcile:

```bash
flux reconcile kustomization infra-main --with-source
```

The DR overlay applies recovery patches for both clusters:

- [`patches/cluster-recovery.yaml`](../../infrastructure/overlays/disaster-recovery/patches/cluster-recovery.yaml) — `homelab-postgres`
- [`patches/cluster-recovery-immich.yaml`](../../infrastructure/overlays/disaster-recovery/patches/cluster-recovery-immich.yaml) — `immich-postgres`

Each injects `bootstrap.recovery` from its S3 prefix under `cnpg-backups/`.

When restoring clusters with the **same name** into the **same S3 prefix** as production backups, CNPG requires
`cnpg.io/skipEmptyWalArchiveCheck: enabled` on the Cluster (included in the DR patches). Without it, recovery pods fail with
`Expected empty archive`.

### 3. Wait for CNPG recovery

```bash
kubectl wait --for=condition=Ready cluster/homelab-postgres -n cnpg-system --timeout=30m
kubectl wait --for=condition=Ready cluster/immich-postgres -n cnpg-system --timeout=30m
kubectl get cluster -n cnpg-system homelab-postgres immich-postgres -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,READY:.status.conditions[?(@.type==\'Ready\')].status
```

Managed roles and `Database` CRs reconcile after the cluster becomes primary.

### 4. Restore normal overlay

Revert `infra-main` path to:

```yaml
path: ./infrastructure/overlays/main
```

Reconcile infrastructure, then resume apps:

```bash
flux reconcile kustomization infra-main --with-source
flux resume kustomization apps -n flux-system
flux reconcile kustomization apps --with-source
```

### 5. Validate applications

```bash
just validate
kubectl get database -A
```

## Credentials

| Method | File |
|--------|------|
| SOPS (default) | `infrastructure/overlays/main/database-clusters/barman-s3-credentials.secret.yaml` |
| Template | `barman-s3-credentials.secret.yaml.template` |
| External Secrets | `external-secret.barman-s3.example.yaml` |

```bash
cd infrastructure/overlays/main/database-clusters
just sops-create cnpg-barman-s3-credentials cnpg-system \
  ACCESS_KEY_ID=xxx ACCESS_SECRET_KEY=yyy
# Produces barman-s3-credentials.secret.yaml (encrypted). Use real Garage/S3 keys, not placeholders.
```

## Velero vs Barman

| Layer | Tool | Purpose |
|-------|------|---------|
| PostgreSQL logical/physical | Barman (`barmanObjectStore`) | PITR, cross-cluster restore |
| Kubernetes volumes | Velero | Namespace/PV disaster recovery |

[`restore.yaml`](../../infrastructure/overlays/main/database-clusters/restore.yaml) remains for optional Velero-based CNPG namespace restore.
