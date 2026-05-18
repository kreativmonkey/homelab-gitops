# CNPG Backup & Disaster Recovery (S3 / Barman)

Central PostgreSQL (`homelab-postgres`) uses **Barman Cloud** via `barmanObjectStore` for continuous WAL archiving and scheduled base backups to S3-compatible storage (same Garage endpoint as Velero).

## Prerequisites

1. S3 bucket `cnpg-backups` exists on the object store (create manually before first reconcile).
2. S3 credentials in `cnpg-barman-s3-credentials` (SOPS or ExternalSecret — never plaintext in Git).
3. CNPG operator and cluster healthy in normal operation (`infrastructure/overlays/main`).

## Normal operation (backup)

Flux path: `./infrastructure/overlays/main`

- WAL archived continuously (`archive_timeout` default ~5 min RPO)
- `ScheduledBackup` `homelab-postgres-daily` at 02:30 UTC
- Retention: `30d` on object store

Verify:

```bash
kubectl get cluster -n cnpg-system homelab-postgres
kubectl get scheduledbackup -n cnpg-system
kubectl get backup -n cnpg-system
```

## Disaster recovery (full cluster rebuild)

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

The DR overlay applies [`patches/cluster-recovery.yaml`](../../infrastructure/overlays/disaster-recovery/patches/cluster-recovery.yaml), injecting `bootstrap.recovery` from S3.

### 3. Wait for CNPG recovery

```bash
kubectl wait --for=condition=Ready cluster/homelab-postgres -n cnpg-system --timeout=30m
kubectl get cluster -n cnpg-system homelab-postgres -o yaml | grep -A5 phase
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
just sops-encrypt cnpg-barman-s3-credentials.secret.yaml
```

## Velero vs Barman

| Layer | Tool | Purpose |
|-------|------|---------|
| PostgreSQL logical/physical | Barman (`barmanObjectStore`) | PITR, cross-cluster restore |
| Kubernetes volumes | Velero | Namespace/PV disaster recovery |

[`restore.yaml`](../../infrastructure/overlays/main/database-clusters/restore.yaml) remains for optional Velero-based CNPG namespace restore.
