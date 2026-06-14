# Nextcloud iSCSI Volume: Emergency Read-Only Remount

**Date**: 2026-06-13
**Severity**: high
**Affected**: app
**Status**: resolved

## What Went Wrong

Nextcloud pod entered CrashLoopBackOff (41 restarts over 35h) with:

```
/entrypoint.sh: 169: cannot create /var/www/html/nextcloud-init-sync.lock: Read-only file system
```

Init containers (`occ-db-sync`, `cleanup-mounts`, `occ-oidc-setup`, `occ-collab-setup`) all completed successfully before the main container started. The iSCSI volume `nextcloud-app-iscsi` (10Gi, ext4) was mounted read-only by the kernel.

## Why It Failed

The ext4 filesystem on `/dev/sde` (iSCSI LUN from TrueNAS) was remounted with the `emergency_ro` flag. This happens when ext4 detects filesystem corruption (I/O errors, dirty shutdown, SCSI reservation conflict, or iSCSI session loss) and the kernel automatically switches to read-only to prevent further damage.

Mount options before fix:
```
/dev/sde on .../globalmount type ext4 (rw,relatime,seclabel,stripe=2048,emergency_ro)
```

The CSI driver's `NodeStageVolume` was not called because the pod was already running with the volume attached — the kernel silently flipped the mount to read-only without detaching the iSCSI session.

## The Correct Approach

### 1. Identify the affected block device

```bash
# Find the CSI node pod on the node where the nextcloud pod runs
kubectl get pods -n democratic-csi -o wide | grep <node-name>

# List block devices and find the 10G device
kubectl exec -n democratic-csi <csi-node-pod> -c csi-driver -- lsblk -o NAME,SIZE,FSTYPE

# Confirm it's the right device (ext4, 10G)
kubectl exec -n democratic-csi <csi-node-pod> -c csi-driver -- sh -c "blkid /dev/sde"
```

### 2. Unmount all subpaths and the globalmount

```bash
kubectl exec -n democratic-csi <csi-node-pod> -c csi-driver -- sh -c '
# Unmount all subpath mounts first (reverse order)
for mp in $(findmnt -n -o TARGET /dev/sde 2>/dev/null | sort -r); do
  echo "Unmounting $mp"
  umount "$mp" 2>/dev/null || true
done

# Unmount globalmount
GLOBAL="<globalmount-path>"
umount "$GLOBAL" 2>/dev/null || true

# Unmount the device itself
umount /dev/sde 2>/dev/null || true
'
```

### 3. Repair the filesystem

```bash
kubectl exec -n democratic-csi <csi-node-pod> -c csi-driver -- sh -c '
e2fsck -f -y /dev/sde
'
# Expected: "recovering journal" + clean pass through all 5 checks
```

### 4. Restart the CSI node pod (forces fresh NodeStageVolume)

```bash
kubectl delete pod <csi-node-pod> -n democratic-csi
# Wait for new pod to come up
```

### 5. Manually mount at globalmount (if CSI driver doesn't auto-stage)

```bash
kubectl exec -n democratic-csi <new-csi-node-pod> -c csi-driver -- sh -c '
GLOBAL="<globalmount-path>"
mkdir -p "$GLOBAL"
mount -t ext4 /dev/sde "$GLOBAL"
'
```

### 6. Delete the stuck Nextcloud pod

```bash
kubectl delete pod -n nextcloud -l app.kubernetes.io/name=nextcloud,app.kubernetes.io/component=app
# Wait for new pod to initialize (init containers + startup probe)
```

### 7. Verify

```bash
# Confirm volume is mounted rw (no emergency_ro)
kubectl exec -n democratic-csi <csi-node-pod> -c csi-driver -- sh -c "findmnt -n -o OPTIONS /dev/sde"
# Expected: rw,relatime,seclabel,stripe=2048 (no emergency_ro)

# Confirm Nextcloud is healthy
kubectl get pods -n nextcloud -l app.kubernetes.io/name=nextcloud,app.kubernetes.io/component=app
# Expected: 1/1 Running
```

## Deployment Fixes Applied

| File | Change | Why |
|------|--------|-----|
| `apps/base/nextcloud/helmrelease.yaml` | Added `fsGroupChangePolicy: OnRootMismatch` to `podSecurityContext` | Prevents full-volume chown on every pod start; avoids timeout-induced re-mounts |
| `apps/base/nextcloud/helmrelease.yaml` | Added `terminationGracePeriodSeconds: 60` | Gives iSCSI time for clean SCSI reservation release on shutdown |

## Prevention

**Implemented:**

| Date | Change | File |
|------|--------|------|
| 2026-06-13 | `fsGroupChangePolicy: OnRootMismatch` — prevents full-volume chown on pod start | `apps/base/nextcloud/helmrelease.yaml` |
| 2026-06-13 | `terminationGracePeriodSeconds: 60` — clean iSCSI disconnect on shutdown | `apps/base/nextcloud/helmrelease.yaml` |
| 2026-06-13 | VMRule `IScsiEmergencyReadOnly` — alerts when ext4 mounts go read-only | `apps/base/monitoring/rules/storage-iscsi-vmrule.yaml` |
| 2026-06-13 | StorageClass `truenas-iscsi-xfs` — XFS option for future volumes (better journal recovery) | `infrastructure/base/storage/democratic-csi/helmrelease.yaml` |

**Still recommended:**
- Monitor `emergency_ro` mount options via the new alert rule.
- For new iSCSI volumes, prefer `truenas-iscsi-xfs` (XFS handles journal recovery more gracefully than ext4 under iSCSI).
- If the issue recurs frequently on a specific volume, migrate it from ext4 to XFS (requires PVC recreation).

## Related

- Learning: [democratic-csi-pvc-resize-permission-denied.md](democratic-csi-pvc-resize-permission-denied.md) — related iSCSI issue on Talos
- Files: `apps/base/nextcloud/helmrelease.yaml`
- Files: `infrastructure/base/storage/democratic-csi/helmrelease.yaml`
- Runbook: `docs/runbooks/nextcloud-init-crashloop.md`
