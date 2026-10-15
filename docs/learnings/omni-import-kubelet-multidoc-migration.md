# Omni Import: K8s Upgrade Blocked by Legacy `.machine.kubelet`

**Date**: 2026-10-15
**Severity**: high
**Affected**: cluster-wide (all nodes, node-local storage, Kubernetes upgrades)
**Status**: resolved

## What Went Wrong

After importing `homelab-kube` into Omni, the Omni Kubernetes upgrade
1.36.0 → 1.36.5 stalled at `talos-cp1: updating kubelet` with
`waiting for the cluster to be ready`. Omni showed:

```
kubelet config is already set in v1alpha1 config (.machine.kubelet)
```

The control plane already ran 1.36.5, kubelets stayed on 1.36.0.

## Why It Failed

- Omni's import stores the node config as per-machine patches
  (`10-<machine-uuid>`) — including the legacy `.machine.kubelet` block
  (image, `extraMounts` for the data disk, seccomp) and `.machine.disks`.
- For upgrades Omni writes a system patch with a Talos 1.14 multi-doc
  `KubeletConfig` document. Talos rejects **any** `.machine.kubelet` next to it
  (`V1Alpha1ConflictValidate`).
- `KubeletConfig` has no `extraMounts`. kubelet only sees `/var/mnt`
  (rbind, rslave). The data disk on `/var/lib/longhorn` would vanish for
  kubelet again — the silent subPath/local-PV failure from
  [talos-kubelet-extramounts-local-storage.md](talos-kubelet-extramounts-local-storage.md).

## The Correct Approach

1. Mount the data disk as a Talos `ExistingVolumeConfig` under `/var/mnt`
   (no reformat, `mount.secure: false` keeps exec for dind):
   ```yaml
   apiVersion: v1alpha1
   kind: ExistingVolumeConfig
   name: local-storage
   discovery:
     volumeSelector:
       match: disk.dev_path == "/dev/sdb" && volume.partition_index == 1u && volume.name == "xfs"
   mount:
     secure: false
   ```
   Drop `.machine.kubelet` and `.machine.disks`, keep seccomp via a partial
   `KubeletConfig` document.
2. Per node, one at a time: cordon, re-bootstrap the CNPG instances on it
   (delete pod+PVC, primaries switched over first), release static `local` PVs
   (Retain), drain, apply the patch, reboot, point local-path at the new path,
   prove hostPath view == subPath view with a test pod, uncordon.
3. hostPath/`local` PV paths are immutable: CNPG re-clones, the Nextcloud PV
   was re-created on the same data (Retain), caches were dropped.

Validate a patch locally before Omni sees it: transform the running config and
run `talosctl validate --mode metal`. A negative test (old config + a
`KubeletConfig` doc) reproduces the exact Omni error.

## Traps Hit on the Way

- **Omni rolls control-plane config one node at a time.** A node whose config
  fails to render occupies the slot and blocks every other node. Give the
  broken node a valid interim patch (only `.machine.kubelet` removed) to free it.
- **`talosctl reboot` hangs in `teardownLifecycle`** after `.machine.disks` is
  removed (legacy VolumeConfig "pending finalizers"). Filesystems are already
  unmounted at that point; `talosctl reboot --mode force` is safe.
- **Hand-editing the local-path ConfigMap:** suspend the Flux Kustomization
  first (`kubectl patch kustomization … spec.suspend=true` — the `flux` CLI only
  exists in `nix develop`), else Flux reverts it. Then `rollout restart` the
  provisioner — the mounted ConfigMap updates too late and the next PVs land on
  the old path. The image is distroless, `kubectl exec … cat` does not work.
- **Helm waits on a WaitForFirstConsumer PVC** that only a CronJob consumes
  (renovate cache): start the job once manually.

## Prevention

- Node config, Talos and Kubernetes versions are declared only in
  `infrastructure/base/omni-sync/cluster-template.yaml`; `omni-sync` pushes it.
  No `talosctl patch`, no OpenTofu machine config, no Omni UI edits.
- Before a Talos minor upgrade, check the deprecated-field map
  (`talos/vX/reference/configuration/document-map`) against the template —
  removed fields fail only at render time, inside the upgrade.

## Related

- [talos-kubelet-extramounts-local-storage.md](talos-kubelet-extramounts-local-storage.md)
- [Talos 1.14 document map](https://docs.siderolabs.com/talos/v1.14/reference/configuration/document-map.md)
- [ExistingVolumeConfig](https://docs.siderolabs.com/talos/v1.14/reference/configuration/block/existingvolumeconfig.md)
- [Omni: importing Talos clusters](https://docs.siderolabs.com/omni/cluster-management/importing-talos-clusters.md)
