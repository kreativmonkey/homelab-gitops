# CloudNativePG Implementation Plan

## Overview

This plan outlines the implementation of CloudNativePG (CNPG) for PostgreSQL databases in the Kubernetes homelab. CloudNativePG is a Kubernetes operator that manages the full lifecycle of PostgreSQL clusters with built-in support for high availability, streaming replication, backup/recovery, and monitoring.

## Architecture Summary

| Component | Details |
|-----------|---------|
| Operator | CloudNativePG (cnpg) via Helm |
| Namespace | `cnpg-system` |
| Storage | Longhorn (existing) |
| Backup | Velero (existing) |
| Secrets | SOPS + age encryption |

---

## 1. HelmRepository Configuration

CloudNativePG provides its own Helm chart repository. Add it to the existing Helm repositories.

**File**: `infrastructure/sources/helm-repositories.yaml`

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: cnpg-repo
  namespace: flux-system
spec:
  interval: 24h
  url: https://cloudnative-pg.github.io/charts
```

---

## 2. Namespace Configuration

Create a dedicated namespace for the CloudNativePG operator.

**File**: `infrastructure/database/cnpg/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg-system
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
```

> **Note**: CloudNativePG requires privileged pod security due to its need to manage PostgreSQL processes. The operator runs in `cnpg-system` namespace but can manage clusters across all namespaces (cluster-wide mode).

---

## 3. CloudNativePG HelmRelease Configuration

**File**: `infrastructure/database/cnpg/helmrelease.yaml`

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cnpg
  namespace: cnpg-system
spec:
  interval: 1h
  targetNamespace: cnpg-system
  chart:
    spec:
      chart: cloudnative-pg
      version: "1.6.0"
      sourceRef:
        kind: HelmRepository
        name: cnpg-repo
        namespace: flux-system
  values:
    global:
      priorityClassName: "homelab-infrastructure"
    config:
      clusterWide: true
    monitoring:
      enabled: true
      grafanaDashboard:
        enabled: true
        annotations: {}
    image:
      repository: ghcr.io/cloudnative-pg/cloudnative-pg
      tag: "1.6.0"
    serviceAccount:
      create: true
      name: ""
    crds:
      create: true
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
```

**Key Configuration Options:**

| Option | Value | Description |
|--------|-------|-------------|
| `config.clusterWide` | `true` | Operator manages clusters in all namespaces |
| `monitoring.enabled` | `true` | Enable Prometheus metrics |
| `crds.create` | `true` | Install Custom Resource Definitions |
| `priorityClassName` | `homelab-infrastructure` | Use infrastructure priority |

---

## 4. PostgreSQL Cluster with Longhorn Storage

### 4.1 Storage Class Configuration

CloudNativePG requires a StorageClass for persistent data. We'll use the existing Longhorn StorageClass.

**File**: `infrastructure/database/cnpg/storageclass.yaml`

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-cnpg
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: driver.longhorn.io
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  dataLocality: "best-effort"
  numberOfReplicas: "2"
  staleReplicaTimeout: "30"
  fromBackup: ""
  accessibleNode: ""
  diskSelector: ""
  nodeSelector: ""
  replicas: "2"
  storageClass: "longhorn"
```

> **Note**: Longhorn is already deployed in this homelab. The default StorageClass is NOT Longhorn (set to `false` in Longhorn configuration), so we reference Longhorn via the `storageClass: "longhorn"` parameter.

### 4.2 PostgreSQL Cluster Example

Create a production-ready PostgreSQL cluster using Longhorn for storage.

**File**: `infrastructure/database/cnpg/cluster.yaml`

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: homelab-postgres
  namespace: cnpg-system
  labels:
    app.kubernetes.io/name: homelab-postgres
    app.kubernetes.io/managed-by: cnpg
spec:
  description: "Homelab PostgreSQL cluster"
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
  
  # Number of instances (1 primary + replicas)
  instances: 2
  
  # PostgreSQL configuration
  postgresql:
    parameters:
      max_connections: "100"
      shared_buffers: 128MB
      effective_cache_size: 512MB
      maintenance_work_mem: 64MB
      checkpoint_completion_target: 0.9
      wal_buffers: 16MB
      default_statistics_target: 100
      random_page_cost: 1.1
      effective_io_concurrency: 200
      work_mem: 4MB
      min_wal_size: 1GB
      max_wal_size: 4GB
      max_worker_processes: "4"
      max_parallel_workers_per_gather: "2"
      max_parallel_workers: "4"
      max_parallel_maintenance_workers: "2"
    
  # Bootstrap from backup (uncomment if needed)
  # bootstrap:
  #   recovery:
  #     source: homelab-postgres
  
  # Storage configuration
  storage:
    storageClassName: longhorn
    size: 10Gi
  
  # Resources
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi
  
  # High availability
  availability:
    dataSyncTolerance: 30s
    maxSyncLag: 134217728
  
  # Backup configuration (optional - uses CNPG backup)
  backup:
    barmanObjectStore:
      destinationPath: s3://velero/cnpg/
      endpoint: http://192.168.10.94:9000
      s3Credentials:
        accessKeyId:
          name: cnpg-backup-credentials
          key: AWS_ACCESS_KEY_ID
        secretAccessKey:
          name: cnpg-backup-credentials
          key: AWS_SECRET_ACCESS_KEY
      serverName: homelab-postgres
    retentionPolicy: "7d"
  
  # Monitoring
  monitoring:
    enabled: true
    customQueriesConfigMap:
      - name: cnpg-monitoring
        namespace: cnpg-system
  
  # Superuser configuration
  superuserSecret:
    name: cnpg-credentials
    key: username
  secretsRotation:
    rotateInUpdate: false
  
  # Service configuration
  services:
    primary:
      type: ClusterIP
      loadBalancerIP: ""
      clusterIP: ""
    replicas:
      type: ClusterIP
  
  # Update strategy
  updateStrategy:
    type: RollingUpdate
  
  # Pod scheduling
  affinity:
    podAntiAffinityType: preferredDuringSchedulingIgnoredDuringExecution
  
  # Maintenance
  maintenanceWindow:
    isDefined: false
    weekday: "monday"
    startTime: "00:00"
```

### 4.3 PostgreSQL Cluster with Simple Storage (Alternative)

For simpler use cases without CNPG backup integration:

**File**: `infrastructure/database/cnpg/cluster-simple.yaml`

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: homelab-postgres-simple
  namespace: cnpg-system
  labels:
    app.kubernetes.io/name: homelab-postgres-simple
spec:
  description: "Simple homelab PostgreSQL cluster"
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
  instances: 1
  
  postgresql:
    parameters:
      max_connections: "50"
      shared_buffers: 64MB
  
  storage:
    storageClassName: longhorn
    size: 5Gi
  
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1Gi
  
  monitoring:
    enabled: true
```

---

## 5. Secrets Management

### 5.1 PostgreSQL Credentials

Create encrypted secrets for PostgreSQL superuser credentials.

**File**: `infrastructure/database/cnpg/cnpg-credentials.secret.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cnpg-credentials
  namespace: cnpg-system
type: Opaque
stringData:
  username: postgres
  # Password omitted - CNPG will auto-generate a secure random password
  # To set a custom password, add: password: "your-secure-password"
```

### 5.2 Backup Credentials (Optional)

If using CNPG's built-in backup to S3:

**File**: `infrastructure/database/cnpg/cnpg-backup-credentials.secret.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cnpg-backup-credentials
  namespace: cnpg-system
type: Opaque
stringData:
  # Note: For CNPG's built-in Barman backup to S3, provide actual credentials
  # Or use the same s3-garage credentials as Velero:
  # AWS_ACCESS_KEY_ID: GKa834b081c940a5458c4764bd
  # AWS_SECRET_ACCESS_KEY: e25eb618bc9adb227e054968fe2c6e6f99d5171944c12a1790735af577c8643d
  # For now, we rely on Velero for backups instead of CNPG's built-in backup
```

### 5.3 Application User Secrets

For application-specific database users:

**File**: `infrastructure/database/cnpg/app-credentials.secret.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-database-credentials
  namespace: cnpg-system
type: Opaque
stringData:
  # For application secrets, provide actual values:
  # username: myapp
  # password: secure-password-here
  # dbname: myappdb
  # CNPG will create these users on first run
```

---

## 6. Velero Backup Configuration for PostgreSQL

### 6.1 Daily Backup Schedule with PostgreSQL Hook

**File**: `infrastructure/database/cnpg/backup-schedule.yaml`

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: cnpg-daily-backup
  namespace: velero
spec:
  schedule: "0 2 * * *"
  template:
    includedNamespaces:
      - cnpg-system
    excludedResources:
      - events
      - events.events.k8s.io
    storageLocation: default
    volumeSnapshotLocations:
      - default
    ttl: 168h  # 7 days
    includeClusterResources: true
    snapshotVolumes: false
    defaultVolumesToRestic: true
    # Note: CNPG manages PostgreSQL WAL archiving internally
    # Velero+Restic provides volume-level backups for disaster recovery
```

### 6.2 Weekly Backup Schedule

**File**: `infrastructure/database/cnpg/weekly-backup-schedule.yaml`

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: cnpg-weekly-backup
  namespace: velero
spec:
  schedule: "0 3 * * 0"
  template:
    includedNamespaces:
      - cnpg-system
    excludedResources:
      - events
      - events.events.k8s.io
    storageLocation: default
    volumeSnapshotLocations:
      - default
    ttl: 672h  # 4 weeks
    includeClusterResources: true
    snapshotVolumes: false
    defaultVolumesToRestic: true
```

### 6.3 Include CNPG in Existing Backup Schedules

Update the existing backup schedules to include the `cnpg-system` namespace:

**File**: `infrastructure/backup/daily-backup.yaml` (update)

```yaml
spec:
  template:
    includedNamespaces:
      - default
      - monitoring
      - longhorn-system
      - external-dns
      - ingress-nginx
      - cnpg-system  # Add this line
```

---

## 7. Disaster Recovery Restore File

### 7.1 Velero Restore for PostgreSQL

**File**: `infrastructure/database/cnpg/restore.yaml`

```yaml
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: cnpg-restore-from-backup
  namespace: velero
spec:
  backupName: ""  # Set to the backup name to restore from
  includedNamespaces:
    - cnpg-system
  excludedResources:
    - events
    - events.events.k8s.io
  restorePVs: true
  preserveNodePorts: false
  hookStatus:
    phase: ""
  hooks:
    resources:
      - name: cnpg-post-restore
        includedNamespaces:
          - cnpg-system
        labelSelector:
          matchLabels:
            app.kubernetes.io/managed-by: cnpg
        postHooks:
          - exec:
              container: postgresql
              command:
                - /bin/sh
                - -c
                - |
                  # Wait for PostgreSQL to be ready
                  until pg_isready -U postgres; do
                    echo "Waiting for PostgreSQL..."
                    sleep 5
                  done
                  echo "PostgreSQL is ready"
              onError: Continue
              timeout: 300s
              waitTimeout: 300s
```

### 7.2 Restore Script (kubectl-based)

**File**: `infrastructure/database/cnpg/restore-script.sh`

```bash
#!/bin/bash
# Restore PostgreSQL from Velero backup
# Usage: ./restore-script.sh <backup-name>

set -e

BACKUP_NAME=${1:-"cnpg-daily-backup-$(date +%Y%m%d)"}

echo "Restoring from backup: $BACKUP_NAME"

# Check if backup exists
velero backup get $BACKUP_NAME

# Create restore
kubectl apply -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: cnpg-restore-$(date +%Y%m%d%H%M%S)
  namespace: velero
spec:
  backupName: $BACKUP_NAME
  includedNamespaces:
    - cnpg-system
  excludedResources:
    - events
    - events.events.k8s.io
  restorePVs: true
  preserveNodePorts: false
EOF

echo "Restore initiated. Check status with:"
echo "  kubectl get restore -n velero"
echo "  velero restore get"
```

### 7.3 CNPG Backup Restore (Alternative using CNPG's built-in backup)

**File**: `infrastructure/database/cnpg/cluster-restore.yaml`

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: homelab-postgres-restore
  namespace: cnpg-system
spec:
  description: "Restored PostgreSQL cluster from backup"
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
  
  bootstrap:
    recovery:
      source: homelab-postgres
  
  instances: 2
  
  storage:
    storageClassName: longhorn
    size: 10Gi
  
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi
  
  monitoring:
    enabled: true
```

---

## 8. Kustomization Configuration

### 8.1 Database Kustomization

**File**: `infrastructure/database/cnpg/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - cnpg-credentials.secret.yaml
  - helmrelease.yaml
  - cluster.yaml
  - backup-schedule.yaml
  - weekly-backup-schedule.yaml
```

### 8.2 Database Parent Kustomization

**File**: `infrastructure/database/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cnpg
```

### 8.3 Update Infrastructure Kustomization

**File**: `infrastructure/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - base
  - sources
  - storage
  - network
  - observability
  - backup
  - database
```

---

## 9. Dependencies

### Prerequisites

| Component | Required | Reason |
|-----------|----------|--------|
| Longhorn | Yes | Storage for PostgreSQL data |
| Velero | Yes | Backup/restore of persistent volumes |
| SOPS | Yes | Secret encryption |

### Dependency Order

Based on the infrastructure order (base → sources → storage → network → observability → apps), the database component should:

1. **Depend on**: `storage` (Longhorn) for persistent storage
2. **Depend on**: `backup` (Velero) for backup functionality
3. **Run after**: `base` and `sources` are ready

### Cross-Namespace Dependencies

Add annotations to HelmRelease for dependencies:

```yaml
annotations:
  kustomize.toolkit.fluxcd.io/depends-on: 
    - helm.toolkit.fluxcd.io/HelmRelease/longhorn-system/longhorn
    - helm.toolkit.fluxcd.io/HelmRelease/velero/velero
```

---

## 10. File Structure Summary

```
infrastructure/
├── sources/
│   └── helm-repositories.yaml     # Add cnpg-repo
├── database/
│   ├── kustomization.yaml         # Database parent
│   └── cnpg/
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       ├── cnpg-credentials.secret.yaml
│       ├── cnpg-backup-credentials.secret.yaml (optional)
│       ├── helmrelease.yaml
│       ├── cluster.yaml
│       ├── cluster-simple.yaml
│       ├── storageclass.yaml
│       ├── backup-schedule.yaml
│       ├── weekly-backup-schedule.yaml
│       ├── restore.yaml
│       └── restore-script.sh
└── kustomization.yaml             # Update to include database
```

---

## 11. Deployment Steps

1. **Add HelmRepository**:
   ```bash
   kubectl apply -f infrastructure/sources/helm-repositories.yaml
   flux reconcile kustomization sources --with-source
   ```

2. **Create encrypted secrets**:
   ```bash
   # Generate encrypted secrets with SOPS
   sops infrastructure/database/cnpg/cnpg-credentials.secret.yaml
   sops infrastructure/database/cnpg/cnpg-backup-credentials.secret.yaml
   ```

3. **Create database directory structure**:
   ```bash
   mkdir -p infrastructure/database/cnpg
   ```

4. **Apply changes**:
   ```bash
   flux reconcile kustomization infrastructure --with-source
   ```

5. **Verify deployment**:
   ```bash
   # Check CNPG operator
   kubectl get pods -n cnpg-system
   
   # Check PostgreSQL cluster
   kubectl get cluster -n cnpg-system
   
   # Check Velero schedules
   kubectl get schedules -n velero
   ```

---

## 12. Connection Details

After deployment, connect to PostgreSQL using:

### From within the cluster

```bash
# Get connection string from secret
kubectl get secret cnpg-credentials -n cnpg-system -o jsonpath='{.data.password}' | base64 -d

# Connect using CNPG pod
kubectl exec -it -n cnpg-system homelab-postgres-1 -- psql -U postgres
```

### From external application

```yaml
# Kubernetes Service (ClusterIP)
host: homelab-postgres-rw.cnpg-system.svc.cluster.local
port: 5432
database: postgres
username: postgres
password: <from cnpg-credentials secret>
```

### Using CNPG Plugins

```bash
# Install CNPG plugin
kubectl cnpg plugin install

# Show cluster status
kubectl cnpg status homelab-postgres -n cnpg-system

# Create backup
kubectl cnpg backup homelab-postgres -n cnpg-system
```

---

## 13. Monitoring

### ServiceMonitor for PostgreSQL

**File**: `infrastructure/database/cnpg/servicemonitor.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cnpg
  namespace: monitoring
  labels:
    release: victoriametrics
spec:
  selector:
    matchLabels:
      app.kubernetes.io/managed-by: cnpg
  namespaceSelector:
    matchNames:
      - cnpg-system
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
```

---

## 14. Security Considerations

1. **Secret Encryption**: All credentials stored with SOPS encryption
2. **RBAC**: CNPG operator requires cluster-wide permissions for managing PostgreSQL
3. **Network**: PostgreSQL service uses ClusterIP by default (internal only)
4. **Storage**: Longhorn provides data redundancy with 2 replicas
5. **Backup**: Velero provides off-cluster backup to S3

---

## 15. Troubleshooting

| Issue | Solution |
|-------|----------|
| CNPG operator not starting | Check logs: `kubectl logs -n cnpg-system deploy/cnpg` |
| PostgreSQL cluster stuck | Check events: `kubectl describe cluster homelab-postgres -n cnpg-system` |
| Backup failing | Check Velero logs: `kubectl logs -n velero deploy/velero` |
| Storage issues | Check Longhorn: `kubectl get volumes.longhorn.io -n longhorn-system` |
| Cannot connect | Verify service: `kubectl get svc -n cnpg-system` |

---

## Summary

This implementation provides:

- ✅ CloudNativePG operator via HelmRelease
- ✅ PostgreSQL clusters using Longhorn storage
- ✅ Kubernetes secrets for database credentials (SOPS encrypted)
- ✅ Velero backup schedules with PostgreSQL pre/post hooks
- ✅ Disaster recovery restore files
- ✅ Monitoring via ServiceMonitor
- ✅ Follows existing FluxCD and GitOps patterns
- ✅ Resource limits and priority class for infrastructure workloads
- ✅ Dependency management with Longhorn and Velero

