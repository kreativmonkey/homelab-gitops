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
| 2 | `renovate-data`, `forgejo-runner-data` | **done** (renovate was faulted → empty volume) |
| 3 | `kite-kite-storage`, `sterling-pdf`, `authentik-media` | **done** (rsync via migrate job) |
| 4 | `vm-k8s-stack` (Grafana + VMSingle) | **done** |
| 5 | `pgadmin` | **done** |
| 6 | **`homelab-postgres`** | **done** (Barman recovery → `truenas-iscsi`) |
| 7 | **`immich-postgres`** | **done** (Barman recovery) |
| 8 | `n8n-app`, orphan `immich-restore-work` | **done** |

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

1. Verify Barman backups: `kubectl get backup.postgresql.cnpg.io -n cnpg-system`
2. `flux suspend kustomization apps infra-main -n flux-system`
3. On-demand backup: `Backup` CR per cluster (optional if daily backup is recent)
4. Scale down consumers (authentik, immich, paperless, …)
5. `kubectl delete cluster <name> -n cnpg-system --wait`
6. `./scripts/force-delete-pvc.sh cnpg-system <name>-1`
7. Merge main `cluster.yaml` + DR `patches/cluster-recovery*.yaml` (see `scripts/` — `kubectl patch --local` fails on Cluster CR) and `kubectl apply`
8. `kubectl wait --for=condition=Ready cluster/<name> -n cnpg-system --timeout=45m`
9. `flux resume kustomization apps infra-main -n flux-system`
10. See `docs/disaster-recovery/cnpg-s3-dr.md`

## Decommission Longhorn

When no PVCs use `longhorn` / `longhorn-1`:

```bash
kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName | grep longhorn || true
flux suspend helmrelease longhorn -n longhorn-system
```

Remove from Git: `longhorn.yaml`, `storageclass-longhorn-1.yaml`, Longhorn ingress; optional: drop Talos `/var/lib/longhorn` disk in OpenTofu (separate change).

## Rollback

Keep Longhorn HelmRelease in Git (unsuspended) until all PVCs migrated. Old PVCs on Longhorn remain readable until volumes are deleted.
