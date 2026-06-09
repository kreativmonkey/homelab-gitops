# Democratic-CSI iSCSI PVC Resize: Permission Denied on Talos

**Date**: 2026-06-09
**Severity**: medium
**Affected**: infrastructure
**Status**: workaround

## What Went Wrong

PVC expansion (2Gi → 10Gi) for Renovate cache failed with:

```
MountVolume.MountDevice failed: resize2fs: Permission denied to resize filesystem
```

The PVC capacity was updated, TrueNAS LUN was expanded, but the ext4 filesystem on the iSCSI block device could not be resized on the consumer node.

## Why It Failed

Democratic CSI's `NodeStageVolume` runs `resize2fs` from within the CSI driver container. On Talos Linux, even with `privileged: true` and `CAP_SYS_ADMIN`, online resize of a mounted ext4 filesystem fails with "Permission denied" because the container cannot fully access the host's block device namespace for this specific operation.

The device is mounted at the global mount point (`/var/lib/kubelet/plugins/kubernetes.io/csi/truenas-iscsi/.../globalmount`) when resize2fs needs to run, requiring online resize which the container environment blocks.

## The Correct Approach

1. **Increase PVC size** in the HelmRelease values (e.g., `storageSize: 10Gi`).

2. **Wait for Flux/Helm to update the PVC** and for the TrueNAS CSI driver to expand the iSCSI LUN (the PV will show the new capacity, PVC remains at old size).

3. **Manually resize the filesystem** from the correct CSI node pod:

   ```bash
   # Find which node the PVC is attached to
   kubectl get pods -n democratic-csi -o wide

   # Get the CSI node pod on that node
   CSI_NODE_POD=$(kubectl get pods -n democratic-csi -o name | grep node | grep <node-name>)

   # Find the block device
   kubectl exec -n democratic-csi $CSI_NODE_POD -- sh -c "lsblk | grep sde"

   # Unmount the global mount point (to allow offline resize)
   MOUNT_PATH=$(kubectl exec -n democratic-csi $CSI_NODE_POD -- sh -c "findmnt -n -o TARGET /dev/sde 2>/dev/null || echo ''")
   kubectl exec -n democratic-csi $CSI_NODE_POD -- umount "$MOUNT_PATH"

   # Check filesystem, then resize
   kubectl exec -n democratic-csi $CSI_NODE_POD -- sh -c "e2fsck -f -y /dev/sde && resize2fs /dev/sde"

   # Remount (or let kubelet retry the pod mount which will re-trigger NodeStageVolume)
   # After this, a new pod mounting the PVC will succeed.
   ```

4. **Trigger a pod mount** to verify and update PVC status:

   ```bash
   kubectl delete pod <failed-pod> -n <namespace>
   # Create a simple test pod that mounts the PVC and runs df -h
   ```

## Prevention

- Pre-allocate sufficient PVC sizes to avoid resize operations on iSCSI volumes.
- The CSI driver container runs with `privileged: true` and `SYS_ADMIN` but still cannot perform online ext4 resize on Talos. Offline resize (unmount → fsck → resize2fs → remount) is the reliable workaround.
- Consider using `fsType: xfs` for future storage classes — XFS can be grown online more reliably.
- For truly automatic resize, a privileged init container or daemon that runs `resize2fs` via `nsenter` in the host namespace could be added, but requires custom CSI driver configuration.

## Related

- GitHub issue: [democratic-csi#491 — Permission denied to resize PVC iSCSI storage](https://github.com/democratic-csi/democratic-csi/issues/491)
- Files: `infrastructure/base/storage/democratic-csi/helmrelease.yaml`
- Files: `apps/base/renovate/helmrelease.yaml`
