# PVC Migration: Longhorn → NFS (`nfs-media-static`)

## Why this exists

PersistentVolumeClaim specs are **immutable** for the fields
`storageClassName`, `accessModes`, and `volumeName`. When an app is
moved from Longhorn (RWO, dynamic) to NFS (RWX, static `pv-nfs-*`),
the in-cluster PVC must be deleted and recreated — `kubectl apply`
alone returns:

```
PersistentVolumeClaim "<name>" is invalid: spec: Forbidden:
spec is immutable after creation except resources.requests and
volumeAttributesClassName for bound claims
```

This blocks the entire owning Flux Kustomization (server-side
dry-run rejects, no resources reconcile).

## Migration procedure (per app)

> Run inside the talos dev-shell: `cd ../homelab-infrastructure && nix develop .#talos`.

Replace `<ns>` / `<app>` accordingly.

```bash
APP_NS=immich
APP_HR=immich
WORKLOAD=immich-server               # Deployment that holds the PVC
PVC=immich-library                   # PVC to migrate

# 1. Stop Flux from re-creating things during the swap
flux -n "$APP_NS" suspend helmrelease "$APP_HR"

# 2. Optional: snapshot the data first (longhorn UI / velero) - PROD only

# 3. Tear down the workload and PVC
kubectl -n "$APP_NS" delete deployment "$WORKLOAD" --ignore-not-found
kubectl -n "$APP_NS" delete pvc "$PVC" --wait=false --ignore-not-found

# 4. If the PVC has stuck finalizers
kubectl -n "$APP_NS" patch pvc "$PVC" -p '{"metadata":{"finalizers":null}}' --type=merge \
  2>/dev/null || true

# 5. Verify the matching static PV is back to `Available`
kubectl get pv -l app="$APP_NS" -l storage.type=nfs-media

# 6. Resume Flux — it will bind the NFS PV via the new claimRef
flux -n "$APP_NS" resume helmrelease "$APP_HR"

# 7. Watch the pod come up
kubectl -n "$APP_NS" get pods -w
```

## Verifying the result

A successful migration:

```text
NAME                     STATUS   VOLUME                  CAPACITY  ACCESS MODES  STORAGECLASS
immich-library           Bound    pv-nfs-immich-library   2Ti       RWX           nfs-media-static
```

The matching PV transitions from `Available` to `Bound`.

## Data preservation

The static PVs in `infrastructure/base/storage/pv-nfs.yaml` point at
TrueNAS share paths under `/mnt/Storagepool/Media/…`. **Existing
files on those paths are reused** as soon as the PVC binds. Migration
of actual file data (e.g. moving from a Longhorn volume to TrueNAS)
must be done separately, with `rsync` over SSH or via TrueNAS UI,
**before** the Longhorn PVC is deleted.

## Apps currently affected by this migration

Tracked in `apps/overlays/main/kustomization.yaml`:

| App           | Old storage  | New storage         | Status       |
|---------------|--------------|---------------------|--------------|
| immich        | longhorn-1   | nfs-media-static    | migrated     |
| paperless-ngx | longhorn     | nfs-media-static    | migrated     |
| audiobookshelf| —            | nfs-media-static    | clean install|
| jellyfin      | —            | nfs-media-static    | clean install|
| nextcloud     | —            | nfs-media-static    | wip          |
