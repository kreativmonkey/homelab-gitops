# Velero Backup Implementation Plan

## Overview

This plan outlines the implementation of Velero backups in the Kubernetes homelab using S3-compatible storage (s3-garage).

## Storage Configuration

| Parameter | Value |
|-----------|-------|
| S3 Endpoint | `http://192.168.10.94:9000` (s3-garage) |
| Bucket | `velero` |
| Access Key | `[REDACTED]` |
| Secret Key | `[REDACTED]` |

> **Note**: Since this is a homelab using Longhorn without CSI VolumeSnapshots, we will use **Restic** for file-level backups instead of native volume snapshots.

---

## 1. HelmRepository Configuration

Add the Velero HelmRepository to `infrastructure/sources/helm-repositories.yaml`:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: velero-repo
  namespace: flux-system
spec:
  interval: 24h
  url: https://vmware-tanzu.github.io/helm-charts
```

**File**: `infrastructure/sources/helm-repositories.yaml`

---

## 2. Secrets Management (SOPS)

Create an encrypted secret file for S3 credentials:

**File**: `infrastructure/backup/velero-credentials.secret.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: velero-credentials
  namespace: velero
type: Opaque
stringData:
  aws-access-key-id: "[REDACTED]"
  aws-secret-access-key: "[REDACTED]"
```

The file will be encrypted by SOPS based on `.sops.yaml` rules (files ending with `.secret.yaml` are encrypted).

---

## 3. Velero HelmRelease Configuration

**File**: `infrastructure/backup/helmrelease.yaml`

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: velero
  namespace: velero
spec:
  interval: 1h
  targetNamespace: velero
  chart:
    spec:
      chart: velero
      version: "6.0.1"
      sourceRef:
        kind: HelmRepository
        name: velero-repo
        namespace: flux-system
  values:
    global:
      priorityClassName: "homelab-infrastructure"
    configuration:
      provider: aws
      backupStorageLocation:
        name: default
        bucket: velero
        config:
          region: us-east-1
          s3Url: http://192.168.10.94:9000
          insecureSkipTLSVerify: "true"
          s3ForcePathStyle: "true"
      volumeSnapshotLocation:
        name: default
        config:
          region: us-east-1
      features: EnableCSI
      restic:
        enabled: true
    credentials:
      existingSecret: velero-credentials
    deployRestic:
      enabled: true
    restic:
      priorityClassName: "homelab-infrastructure"
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          cpu: 500m
          memory: 512Mi
    velero:
      priorityClassName: "homelab-infrastructure"
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          cpu: 500m
          memory: 512Mi
```

---

## 4. BackupSchedule Configuration

### Daily Backup (7-day retention)

**File**: `infrastructure/backup/daily-backup.yaml`

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-backup
  namespace: velero
spec:
  schedule: "0 2 * * *"
  template:
    includedNamespaces:
      - default
      - monitoring
      - longhorn-system
      - external-dns
      - ingress-nginx
    excludedResources:
      - events
      - events.events.k8s.io
    storageLocation: default
    volumeSnapshotLocations:
      - default
    ttl: 168h
    includeClusterResources: true
    snapshotVolumes: false
    defaultVolumesToRestic: true
    hooks:
      resources:
        - name: longhorn-backup
          includedNamespaces:
            - longhorn-system
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: longhorn
          pre:
            - exec:
                container: longhorn-manager
                command:
                  - /bin/sh
                  - -c
                  - echo "Pre-hook: Longhorn backup triggered"
                onError: Fail
                timeout: 300s
```

### Weekly Backup (4-week retention)

**File**: `infrastructure/backup/weekly-backup.yaml`

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: weekly-backup
  namespace: velero
spec:
  schedule: "0 3 * * 0"
  template:
    includedNamespaces:
      - '*'
    excludedResources:
      - events
      - events.events.k8s.io
    storageLocation: default
    volumeSnapshotLocations:
      - default
    ttl: 672h
    includeClusterResources: true
    snapshotVolumes: false
    defaultVolumesToRestic: true
    hooks:
      resources:
        - name: longhorn-backup
          includedNamespaces:
            - longhorn-system
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: longhorn
          pre:
            - exec:
                container: longhorn-manager
                command:
                  - /bin/sh
                  - -c
                  - echo "Pre-hook: Longhorn backup triggered"
                onError: Fail
                timeout: 300s
```

### Retention Summary

| Schedule | Frequency | Retention | TTL | Use Case |
|----------|-----------|-----------|-----|----------|
| daily-backup | Daily at 02:00 | 7 days | 168h | Short-term recovery |
| weekly-backup | Weekly Sunday 03:00 | 4 weeks | 672h | Monthly archive |

---

## 5. VolumeSnapshotLocation

**Not Required**: Since we're using Restic for file-level backups and not CSI VolumeSnapshots, a VolumeSnapshotLocation is not needed. The `snapshotVolumes: false` and `defaultVolumesToRestic: true` settings in the BackupSchedule ensure that Velero uses Restic instead of CSI snapshots.

---

## 6. Kustomization Updates

### Update Backup Kustomization

**File**: `infrastructure/backup/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - velero-credentials.secret.yaml
  - helmrelease.yaml
  - daily-backup.yaml
  - weekly-backup.yaml
```

### Add Backup to Infrastructure

Add backup to the main infrastructure kustomization (`infrastructure/kustomization.yaml`):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - base
  - sources
  - storage
  - network
  - observability
  - backup  # Add this line
```

---

## 7. Dependencies

### Prerequisites

Based on the dependency order (base → sources → storage → network → observability → apps), the backup component should:

1. **Depend on**: `storage` (Longhorn) for backing up persistent volumes
2. **Depend on**: `network` (cert-manager) for TLS certificates if restoring ingress resources
3. **Run after**: `base` and `sources` are ready

### Cross-Namespace Dependencies

Since backup may need to access resources across namespaces, add the following annotation to the HelmRelease:

```yaml
annotations:
  kustomize.toolkit.fluxcd.io/depends-on: helm.toolkit.fluxcd.io/HelmRelease/longhorn-system/longhorn
```

---

## 8. File Structure Summary

```
infrastructure/
├── sources/
│   └── helm-repositories.yaml  # Add velero-repo
├── backup/
│   ├── namespace.yaml           # Already exists (velero namespace)
│   ├── kustomization.yaml       # Update to include all files
│   ├── velero-credentials.secret.yaml  # NEW: Encrypted S3 credentials
│   ├── helmrelease.yaml         # NEW: Velero HelmRelease
│   ├── daily-backup.yaml       # NEW: Daily backup schedule
│   └── weekly-backup.yaml      # NEW: Weekly backup schedule
└── kustomization.yaml           # Update to include backup
```

---

## 9. Deployment Steps

1. **Add HelmRepository**:
   ```bash
   kubectl apply -f infrastructure/sources/helm-repositories.yaml
   ```

2. **Create encrypted secret**:
   ```bash
   # Create the secret file with plaintext, then encrypt with SOPS
   sops --encrypt --age $(cat ~/.config/sops/age/keys.txt | grep -oP "public key: \K(.*)") infrastructure/backup/velero-credentials.secret.yaml
   ```

3. **Update infrastructure kustomization**:
   - Add `backup` to the resources list in `infrastructure/kustomization.yaml`

4. **Reconcile FluxCD**:
   ```bash
   flux reconcile kustomization infrastructure --with-source
   ```

5. **Verify deployment**:
   ```bash
   kubectl get pods -n velero
   kubectl get schedules -n velero
   ```

---

## 10. Backup/Restore Commands

### Manual Backup

```bash
# Create manual backup
velero backup create manual-backup --include-namespaces default,monitoring

# Check backup status
velero backup get
velero backup describe manual-backup
```

### Restore

```bash
# List available backups
velero backup get

# Restore from backup
velero restore create --from-backup daily-backup-xxxxxx

# Restore specific namespace
velero restore create --from-backup daily-backup-xxxxxx --namespace-mappings old-namespace:new-namespace
```

---

## 11. Monitoring

To monitor Velero backups, add a ServiceMonitor in the `monitoring` namespace:

**File**: `infrastructure/observability/velero-servicemonitor.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: velero
  namespace: monitoring
  labels:
    release: victoriametrics
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: velero
  endpoints:
    - port: http
      path: /metrics
```

---

## 12. Security Considerations

1. **Secret Encryption**: The S3 credentials are stored in a SOPS-encrypted secret
2. **Network**: The S3 endpoint uses HTTP (insecure skip TLS verify) - consider using HTTPS with self-signed cert in production
3. **RBAC**: Velero requires cluster-wide permissions for backup/restore operations
4. **Restic**: Uses password-based encryption for restic repositories (auto-generated by Velero)

---

## 13. Troubleshooting

| Issue | Solution |
|-------|----------|
| Backup failing | Check Velero logs: `kubectl logs -n velero deploy/velero` |
| Restic not initialized | Verify restic repository: `velero restic repo get` |
| S3 connection issues | Verify credentials and endpoint in secret |
| Restore not working | Check namespace exists and has proper RBAC permissions |

---

## Summary

This implementation provides:
- ✅ S3-compatible storage (s3-garage) for backup data
- ✅ Restic integration for file-level backups of persistent volumes
- ✅ Daily backups with 7-day retention
- ✅ Weekly backups with 4-week retention
- ✅ Encrypted secrets with SOPS
- ✅ Resource-friendly configuration (CPU/memory limits)
- ✅ Priority class for infrastructure workloads
- ✅ Dependency on Longhorn storage
