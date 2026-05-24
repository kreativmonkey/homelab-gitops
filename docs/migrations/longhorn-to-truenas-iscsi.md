# Longhorn → TrueNAS iSCSI (democratic-csi)

Replace distributed Longhorn on Talos CP local disks with **block storage on TrueNAS M.2** via iSCSI. **NFS (`nfs-media-static`) stays** for media/RWX.

## Prerequisites

### TrueNAS (192.168.10.94)

1. **User `k8sadmin`** — Credentials → Users → Add  
   - Shell: `nologin`, group privilege: **Local Administrator**
2. **API key** — Credentials → Users → `k8sadmin` → **API Keys** → Add → copy key
3. **iSCSI service** — System → Services → iSCSI → enable, start on boot
4. **Initiator group** — Sharing → Block (iSCSI) → Initiator Groups → Add  
   - *Allow all initiators* (or restrict to Talos IQNs later) → note **id**
5. **Portal** — Portals tab → Add → listen on **192.168.10.94** → note **id**
6. **Datasets** (siblings under M.2 pool — API paths without `/mnt/`):
   - **Volumes:** `FastStorage/ClusterStorage/k8s-volumes` (FILESYSTEM parent; CSI creates zvols)
   - **Snapshots:** `FastStorage/ClusterStorage/k8s-snapshots`
   Do **not** use the existing `k8s-storage` **zvol** as `datasetParentName`.

Discover IDs:

```bash
export TRUENAS_API_KEY='...'
./scripts/truenas-discover-iscsi.sh
```

**TrueNAS 25.04+:** use democratic-csi image tag `next` in the HelmRelease (not `v1.0.6`). Omit `zvolDedup` in the driver config (API rejects it). `VolumeSnapshotClass` needs the CSI snapshot CRDs — leave disabled until installed.

### Cluster

- Talos image includes **`iscsi_tools`** (see `cluster.auto.tfvars` schematic).
- SOPS age key for Flux (`sops-age` in `flux-system`).

## GitOps setup

```bash
cd gitops-homelab/infrastructure/base/storage/democratic-csi
cp truenas-iscsi-driver.secret.yaml.template truenas-iscsi-driver.secret.yaml
# Edit: apiKey, datasetParentName, detachedSnapshotsDatasetParentName, targetGroup* IDs
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops -e -i truenas-iscsi-driver.secret.yaml
```

Enable secret in `democratic-csi/kustomization.yaml`, commit, push GitHub `main`.

```bash
flux reconcile kustomization infra-storage -n flux-system --with-source
kubectl get sc truenas-iscsi
kubectl get pods -n democratic-csi
```

Test:

```yaml
# test-iscsi-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-iscsi
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: truenas-iscsi
  resources:
    requests:
      storage: 1Gi
```

## Migration order (live cluster)

PVC `storageClassName` is **immutable**. Each workload: backup → stop → delete PVC → apply Git with `truenas-iscsi` → restore data.

| Phase | Workload | PVC / notes |
|-------|----------|-------------|
| 1 | Test | ad-hoc 1Gi PVC — **done** (`default/truenas-iscsi-test`) |
| 2 | `renovate-data`, `forgejo-runner-data` | small, low risk |
| 3 | `kite-kite-storage`, `sterling-pdf`, `authentik-media` | stop app, copy or accept empty |
| 4 | `vm-k8s-stack` (Grafana + VMSingle) | metrics gap OK briefly; no longhorn snapshots |
| 5 | `pgadmin` | after DB stable |
| 6 | **`homelab-postgres`** | Barman backup → new cluster/PVC on `truenas-iscsi` or pg_dump restore |
| 7 | **`immich-postgres`** | same as CNPG DR runbook |
| 8 | Remaining `longhorn-1` apps (n8n, linkwarden, …) | per `docs/migrations/nfs-migration.md` pattern |

### Example: generic RWO app PVC

```bash
export KUBECONFIG=homelab-infrastructure/talos/kubeconfig
NS=forgejo
APP=renovate
PVC=renovate-data

flux suspend helmrelease -n "$NS" "$APP" 2>/dev/null || kubectl -n "$NS" scale deploy --all --replicas=0
kubectl -n "$NS" delete pvc "$PVC" --wait=false
# Flux applies new PVC with truenas-iscsi (or create manually)
flux resume helmrelease -n "$NS" "$APP" 2>/dev/null || kubectl -n "$NS" scale deploy --all --replicas=1
```

### CNPG (homelab-postgres / immich-postgres)

Do **not** only change `storageClass` in Git on a running cluster.

1. Verify Barman backups: `kubectl get backup -n cnpg-system`
2. `flux suspend kustomization apps -n flux-system`
3. Scale down consumers (authentik, paperless, …)
4. Backup / export or use CNPG recovery to new PVC on `truenas-iscsi`
5. See `docs/disaster-recovery/cnpg-s3-dr.md`

## Decommission Longhorn

When no PVCs use `longhorn` / `longhorn-1`:

```bash
kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName | grep longhorn || true
flux suspend helmrelease longhorn -n longhorn-system
```

Remove from Git: `longhorn.yaml`, `storageclass-longhorn-1.yaml`, Longhorn ingress; optional: drop Talos `/var/lib/longhorn` disk in OpenTofu (separate change).

## Rollback

Keep Longhorn HelmRelease in Git (unsuspended) until all PVCs migrated. Old PVCs on Longhorn remain readable until volumes are deleted.
