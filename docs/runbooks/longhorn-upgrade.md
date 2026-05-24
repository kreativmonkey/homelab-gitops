# Longhorn staged upgrade

## Symptom

- Flux `HelmRelease/longhorn` **Failed** / **Stalled** with `FailedUpgradePreCheck: upgrading from vX.Y to vA.B for minor version is not supported`
- PVCs stay **Pending** (`longhorn-1` / `longhorn` provisioner unavailable)
- `infra-storage` → `infra-base` → `infra-main` → `apps` kustomizations not Ready

Longhorn only supports **one minor version step** per upgrade (e.g. 1.6 → 1.7, not 1.6 → 1.11).

## Preconditions

- `KUBECONFIG` pointing at the cluster (`homelab-infrastructure/talos/kubeconfig`)
- Helm values match `infrastructure/base/storage/longhorn.yaml` (see script usage below)
- If pre-upgrade hook jobs fail with `dial tcp 10.96.0.1:443: connect: no route to host` on **cp1/cp3**, cordon those nodes so hooks schedule on **cp2** (known Talos/CNI quirk on this cluster)

## Staged upgrade (manual)

```bash
cd homelab-infrastructure && nix develop .#talos

export KUBECONFIG=$PWD/talos/kubeconfig

# Optional: keep hook jobs off broken nodes
kubectl cordon talos-cp1 talos-cp3

flux suspend helmrelease longhorn -n longhorn-system
kubectl -n longhorn-system delete job longhorn-pre-upgrade --ignore-not-found

# Values file must mirror Git HelmRelease values
cat >/tmp/longhorn-upgrade-values.yaml <<'EOF'
global:
  priorityClassName: homelab-infrastructure
persistence:
  defaultClass: false
  defaultDataPath: /var/lib/longhorn
defaultSettings:
  createDefaultDiskLabeledNodes: false
  replicaCount: 1
longhornManager:
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
EOF

./scripts/longhorn-staged-upgrade.sh /tmp/longhorn-upgrade-values.yaml

flux resume helmrelease longhorn -n longhorn-system
flux reconcile helmrelease longhorn -n longhorn-system --with-source
flux reconcile kustomization infra-storage -n flux-system --with-source

kubectl uncordon talos-cp1 talos-cp3
```

The script steps through chart versions **1.7.3 → 1.8.2 → 1.9.2 → 1.10.2 → 1.11.2** (adjust the `VERSIONS` array in `scripts/longhorn-staged-upgrade.sh` if the cluster starts from a different release).

## Verify

```bash
kubectl -n longhorn-system get ds longhorn-manager
helm list -n longhorn-system
flux get helmrelease longhorn -n longhorn-system
kubectl get sc longhorn longhorn-1
kubectl get pvc -A | rg Pending
```

All manager pods should run `longhorn-manager:v1.11.2` (or target version). Test provisioning with a small PVC on `longhorn-1`.

## GitOps note

After a manual staged upgrade, Flux `HelmRelease` chart version in Git should match the live Helm release (`1.11.2` in `infrastructure/base/storage/longhorn.yaml`). Do not redefine the `longhorn` StorageClass in kustomize — only `storageclass-longhorn-1.yaml` is managed in Git.
