# VictoriaMetrics Monitoring Stack Consolidation Plan

## 1. Architecture Overview

### Current State
```
┌─────────────────────────────────────────────────────────────────┐
│                    CURRENT ARCHITECTURE                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────────┐    ┌──────────────────────┐           │
│  │   vmagent           │    │   vmalert            │           │
│  │   (Scraping)        │    │   (Alerting)         │           │
│  │   :153 lines        │    │   :60 lines          │           │
│  └──────────┬──────────┘    └──────────┬──────────┘           │
│             │                            │                      │
│             │      ┌──────────────────────┴──────────┐         │
│             └──────│   victoria-metrics-single       │         │
│                    │   (Storage & Query)              │         │
│                    │   PVC: 10Gi Longhorn             │         │
│                    └─────────────────────────────────┘         │
│                                                                  │
│  Separate directories:                                          │
│  - apps/monitoring/vmagent/                                    │
│  - apps/monitoring/vmalert/                                    │
│  - apps/monitoring/victoria-metrics/                           │
└─────────────────────────────────────────────────────────────────┘
```

### Target State
```
┌─────────────────────────────────────────────────────────────────┐
│                   TARGET ARCHITECTURE                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              victoria-metrics-single                      │  │
│  │  ┌─────────────────────────────────────────────────────┐ │  │
│  │  │  vmselect (Query)  │  vmstorage (Data)  │ vminsert  │ │  │
│  │  ├─────────────────────────────────────────────────────┤ │  │
│  │  │  server.scrape.enabled: true (Built-in vmagent)    │ │  │
│  │  │  server.vmalert.enabled: true (Bundled alerting)   │ │  │
│  │  └─────────────────────────────────────────────────────┘ │  │
│  │                                                            │  │
│  │  PVC: 10Gi Longhorn                                       │  │
│  └──────────────────────────────────────────────────────────┘  │
│                              │                                   │
│                              ▼                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    Grafana                                │  │
│  │  - Dashboards for Kubernetes monitoring                  │  │
│  │  - VictoriaMetrics datasource                            │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
│  Consolidated directory:                                         │
│  - apps/monitoring/victoria-metrics/                           │
│  - apps/monitoring/grafana/ (NEW)                              │
└─────────────────────────────────────────────────────────────────┘
```

### Kubernetes Service Discovery Flow
```
┌─────────────────────────────────────────────────────────────────┐
│           METRICS SCRAPING FLOW (with server.scrape)            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │  Kubernetes  │───▶│   Built-in   │───▶│              │      │
│  │  API Server  │    │   vmagent    │    │ VictoriaMetrics│     │
│  └──────────────┘    │   (scrape)   │    │   Storage     │      │
│         │            └──────────────┘    └──────────────┘      │
│         │                   │                                     │
│         │            ┌──────┴──────┐                            │
│         └───────────▶│   Service  │                            │
│                      │   Monitor   │                            │
│                      │  Discovery  │                            │
│                      └─────────────┘                             │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Components to Consolidate

| Component | Current | Target | Action |
|-----------|---------|--------|--------|
| **VictoriaMetrics Single** | `apps/monitoring/victoria-metrics/` | `apps/monitoring/victoria-metrics/` | ENHANCE |
| **vmagent** | `apps/monitoring/vmagent/` | Bundled in `server.scrape` | DELETE |
| **vmalert** | `apps/monitoring/vmalert/` | Bundled in `server.vmalert` | DELETE |
| **Alert Rules** | `apps/monitoring/vmalert/alert-rules-configmap.yaml` | `server.vmalert.configMap` | TRANSFER |
| **Grafana** | NOT DEPLOYED | `apps/monitoring/grafana/` | CREATE |

---

## 3. Files to Modify

### A. `apps/monitoring/victoria-metrics/helmrelease.yaml`

**Changes Required:**
1. Add `server.scrape.enabled: true` with Kubernetes SD configs
2. Add `server.vmalert.enabled: true` with alert rules
3. Add `server.vmalert.configMap` for custom alert rules
4. Update resources to accommodate bundled components

```yaml
# apps/monitoring/victoria-metrics/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: victoria-metrics
  namespace: monitoring
spec:
  interval: 1h
  chart:
    spec:
      chart: victoria-metrics-single
      version: "0.33.0"
      sourceRef:
        kind: HelmRepository
        name: victoriametrics-repo
        namespace: flux-system
  values:
    server:
      fullnameOverride: victoria-metrics-single
      
      # Persistence
      persistentVolume:
        enabled: true
        existingClaim: vm-data-victoria-metrics-single-0

      # Security Context
      podSecurityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000

      # Resources (INCREASED for bundled components)
      resources:
        limits:
          cpu: "2"
          memory: 4Gi
        requests:
          cpu: "1000m"
          memory: 2Gi

      # Ingress disabled (use separate resource)
      ingress:
        enabled: false

      # Backup annotation
      podAnnotations:
        backup.velero.io/backup-volumes: server-volume

      # Extra Args
      extraArgs:
        retentionPeriod: "1"

      # ============================================
      # BUNDLED SCRAPING (replaces vmagent)
      # ============================================
      scrape:
        enabled: true
        config:
          global:
            scrape_interval: 30s
            evaluation_interval: 30s
          scrape_configs:
            # Kubernetes API Servers
            - job_name: kubernetes-apiservers
              kubernetes_sd_configs:
                - role: endpoints
              scheme: https
              tls_config:
                ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
              relabel_configs:
                - source_labels:
                    - __meta_kubernetes_namespace
                    - __meta_kubernetes_service_name
                    - __meta_kubernetes_endpoint_port_name
                  action: keep
                  regex: default;kubernetes;https

            # Kubernetes Nodes
            - job_name: kubernetes-nodes
              kubernetes_sd_configs:
                - role: node
              scheme: https
              tls_config:
                ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
              relabel_configs:
                - action: labelmap
                  regex: __meta_kubernetes_node_label_(.+)

            # cAdvisor
            - job_name: kubernetes-nodes-cadvisor
              kubernetes_sd_configs:
                - role: node
              scheme: https
              tls_config:
                ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
              metric_path: /metrics/cadvisor
              relabel_configs:
                - action: labelmap
                  regex: __meta_kubernetes_node_label_(.+)
                - target_label: __metrics_path__
                  replacement: /metrics/cadvisor

            # Kubernetes Pods (prometheus.io/scrape annotation)
            - job_name: kubernetes-pods
              kubernetes_sd_configs:
                - role: pod
              relabel_configs:
                - source_labels:
                    - __meta_kubernetes_pod_annotation_prometheus_io_scrape
                  action: keep
                  regex: "true"
                - source_labels:
                    - __meta_kubernetes_pod_annotation_prometheus_io_path
                  action: replace
                  target_label: __metrics_path__
                  regex: (.+)
                - source_labels:
                    - __address__
                    - __meta_kubernetes_pod_annotation_prometheus_io_port
                  action: replace
                  regex: ([^:]+)(?::\d+)?;(\d+)
                  replacement: $1:$2
                  target_label: __address__
                - action: labelmap
                  regex: __meta_kubernetes_pod_label_(.+)
                - source_labels:
                    - __meta_kubernetes_namespace
                  action: replace
                  target_label: kubernetes_namespace
                - source_labels:
                    - __meta_kubernetes_pod_name
                  action: replace
                  target_label: kubernetes_pod_name

            # Kubernetes Service Endpoints
            - job_name: kubernetes-service-endpoints
              kubernetes_sd_configs:
                - role: endpoints
              relabel_configs:
                - source_labels:
                    - __meta_kubernetes_service_annotation_prometheus_io_scrape
                  action: keep
                  regex: "true"
                - source_labels:
                    - __meta_kubernetes_service_annotation_prometheus_io_scheme
                  action: replace
                  target_label: __scheme__
                  regex: (https?)
                - source_labels:
                    - __meta_kubernetes_service_annotation_prometheus_io_path
                  action: replace
                  target_label: __metrics_path__
                  regex: (.+)
                - source_labels:
                    - __address__
                    - __meta_kubernetes_service_annotation_prometheus_io_port
                  action: replace
                  regex: ([^:]+)(?::\d+)?;(\d+)
                  replacement: $1:$2
                  target_label: __address__
                - action: labelmap
                  regex: __meta_kubernetes_service_label_(.+)
                - source_labels:
                    - __meta_kubernetes_namespace
                  action: replace
                  target_label: kubernetes_namespace
                - source_labels:
                    - __meta_kubernetes_service_name
                  action: replace
                  target_label: kubernetes_name

      # ============================================
      # BUNDLED ALERTING (replaces vmalert)
      # ============================================
      vmalert:
        enabled: true
        configMap:
          # Will be created: vmalert-rules
        datasource:
          url: "http://victoria-metrics-single:8428"
        remoteWriteURL: "http://victoria-metrics-single:8428/api/v1/write"
        # No AlertManager configured (optional)
        alertmanager:
          url: ""
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
        podSecurityContext:
          runAsUser: 1000
          runAsGroup: 1000
          fsGroup: 1000
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
              - ALL

---

## 4. Files to Create

### A. `apps/monitoring/victoria-metrics/vmalert-rules-configmap.yaml`

**Purpose:** Centralized alert rules for bundled vmalert

```yaml
# apps/monitoring/victoria-metrics/vmalert-rules-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vmalert-rules
  namespace: monitoring
  labels:
    app: victoria-metrics
    app.kubernetes.io/name: victoria-metrics
    app.kubernetes.io/component: alerting
data:
  alert-rules.yaml: |
    groups:
      - name: kubernetes_resources
        interval: 30s
        rules:
          - alert: KubePodNotReady
            expr: |
              kube_pod_status_phase{namespace!="", phase!="Running", phase!="Succeeded"} == 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} is not ready"
              description: "Pod {{ $labels.namespace }}/{{ $labels.pod }} has been in a non-ready state for more than 5 minutes."
          
          - alert: KubeDeploymentReplicasMismatch
            expr: |
              kube_deployment_spec_replicas{namespace!=""} !=
              kube_deployment_status_replicas_available{namespace!=""}
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Deployment replicas mismatch"
              description: "Deployment {{ $labels.namespace }}/{{ $labels.deployment }} has not matched the expected number of replicas."
          
          - alert: KubeStatefulSetReplicasMismatch
            expr: |
              kube_statefulset_status_replicas_ready{namespace!=""} !=
              kube_statefulset_status_replicas{namespace!=""}
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "StatefulSet replicas mismatch"
              description: "StatefulSet {{ $labels.namespace }}/{{ $labels.statefulset }} has not matched expected replicas."

      - name: node_resources
        interval: 30s
        rules:
          - alert: NodeMemoryUsageHigh
            expr: |
              (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 > 85
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Node memory usage is high"
              description: "Node {{ $labels.node }} memory usage is above 85%."
          
          - alert: NodeDiskUsageHigh
            expr: |
              (node_filesystem_size_bytes{mountpoint!=""} - node_filesystem_avail_bytes{mountpoint!=""}) /
              node_filesystem_size_bytes{mountpoint!=""} * 100 > 90
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Node disk usage is high"
              description: "Disk {{ $labels.device }} on node {{ $labels.node }} is above 90%."

      - name: victoriametrics
        interval: 30s
        rules:
          - alert: VMSelectHighMemoryUsage
            expr: |
              process_resident_memory_bytes{job="victoria-metrics-single"} / 1024 / 1024 / 1024 > 3
            for: 5m
            labels:
              severity: info
            annotations:
              summary: "VictoriaMetrics memory usage is high"
              description: "VictoriaMetrics is using more than 3GB of memory."
          
          - alert: VMAlertManagerNotUp
            expr: |
              up{job=~"vmalert.*"} == 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "VMAlert is down"
              description: "VMAlert instance is down."
```

### B. `apps/monitoring/grafana/kustomization.yaml`

```yaml
# apps/monitoring/grafana/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
  - datasources-configmap.yaml
  - dashboards-configmap.yaml
namespace: monitoring
```

### C. `apps/monitoring/grafana/helmrelease.yaml`

```yaml
# apps/monitoring/grafana/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    kustomize.toolkit.fluxcd.io/depends-on: helm.toolkit.fluxcd.io/HelmRelease/monitoring/victoria-metrics
spec:
  interval: 1h
  chart:
    spec:
      chart: grafana
      version: "8.5.5"
      sourceRef:
        kind: HelmRepository
        name: prometheus-community-repo
        namespace: flux-system
  values:
    adminPassword: ""  # Use secretRef or leave empty for random
    adminUser: admin
    
    ingress:
      enabled: true
      ingressClassName: nginx
      annotations:
        cert-manager.io/cluster-issuer: letsencrypt-production
        nginx.ingress.kubernetes.io/ssl-redirect: "true"
      hosts:
        - grafana.cluster.f4mily.net
      tls:
        - hosts:
            - grafana.cluster.f4mily.net
          secretName: grafana-tls
    
    persistence:
      enabled: true
      storageClassName: longhorn
      size: 2Gi
    
    securityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
    
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
    
    # Disable default dashboards (we'll use ConfigMap)
    dashboardProviders:
      dashboardproviders.yaml:
        apiVersion: 1
        providers: []
    
    # Dashboards from ConfigMap
    dashboards:
      default:
        kubernetes-cluster:
          gnetId: 315
          revision: 2
          datasource: Prometheus
        kubernetes-nodes:
          gnetId: 11074
          revision: 1
          datasource: Prometheus

    podAnnotations:
      backup.velero.io/backup-volumes: grafana-storage
```

### D. `apps/monitoring/grafana/datasources-configmap.yaml`

```yaml
# apps/monitoring/grafana/datasources-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: monitoring
  labels:
    app: grafana
    app.kubernetes.io/name: grafana
    app.kubernetes.io/component: datasource
data:
  datasource.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://victoria-metrics-single:8428
        isDefault: true
        editable: false
```

### E. `apps/monitoring/grafana/dashboards-configmap.yaml`

```yaml
# apps/monitoring/grafana/dashboards-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards
  namespace: monitoring
  labels:
    app: grafana
    app.kubernetes.io/name: grafana
    app.kubernetes.io/component: dashboards
data:
  kubernetes-cluster.json: |
    {
      "dashboard": {
        "title": "Kubernetes Cluster",
        "uid": "kubernetes-cluster",
        "panels": [...]
      }
    }
```

### F. `apps/monitoring/grafana/ingress.yaml`

```yaml
# apps/monitoring/grafana/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - grafana.cluster.f4mily.net
      secretName: grafana-tls
  rules:
    - host: grafana.cluster.f4mily.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: grafana
                port:
                  number: 3000
```

---

## 5. Files to Delete

| File/Directory | Reason |
|----------------|--------|
| `apps/monitoring/vmagent/` | Consolidated into `server.scrape` |
| `apps/monitoring/vmalert/` | Consolidated into `server.vmalert` |
| `apps/monitoring/vmalert/alert-rules-configmap.yaml` | Replaced by `vmalert-rules-configmap.yaml` in victoria-metrics |

### Deletion Commands (Manual Verification Required)

```bash
# Verify no dependencies before deletion
flux tree kustomization apps

# Delete vmagent resources
rm -rf apps/monitoring/vmagent/

# Delete vmalert resources  
rm -rf apps/monitoring/vmalert/
```

---

## 6. Kustomization Updates

### A. `apps/kustomization.yaml`

**Current:**
```yaml
resources:
  - homepage
  - sterling-pdf
  - kite
  - audiobookshelf
  - monitoring/victoria-metrics
  - monitoring/vmagent          # DELETE
  - monitoring/vmalert         # DELETE
```

**Updated:**
```yaml
resources:
  - homepage
  - sterling-pdf
  - kite
  - audiobookshelf
  - monitoring/victoria-metrics
  - monitoring/grafana        # ADD
```

### B. `apps/monitoring/victoria-metrics/kustomization.yaml`

**Current:**
```yaml
resources:
  - pvc.yaml
  - helmrelease.yaml
  - ingress.yaml
```

**Updated:**
```yaml
resources:
  - pvc.yaml
  - helmrelease.yaml
  - ingress.yaml
  - vmalert-rules-configmap.yaml    # ADD
```

---

## 7. Resource Requirements

### VictoriaMetrics Single (Consolidated)

| Resource | Current | Recommended | Reason |
|----------|---------|-------------|--------|
| **CPU Request** | 500m | 1000m | Bundled scraping + alerting |
| **CPU Limit** | 1 | 2 | Peak load handling |
| **Memory Request** | 1Gi | 2Gi | Bundled components |
| **Memory Limit** | 2Gi | 4Gi | Large query buffers |
| **Storage** | 10Gi | 20Gi | Extended retention |

### VMAlert (Bundled)

| Resource | Current | Recommended | Reason |
|----------|---------|-------------|--------|
| **CPU Request** | 100m | 50m | Reduced (co-located) |
| **CPU Limit** | 500m | 200m | Reduced (co-located) |
| **Memory Request** | 128Mi | 128Mi | Alert evaluation |
| **Memory Limit** | 256Mi | 256Mi | Alert evaluation |

### Grafana (New)

| Resource | Request | Limit | Reason |
|----------|---------|-------|--------|
| **CPU** | 100m | 500m | Lightweight UI |
| **Memory** | 128Mi | 512Mi | Dashboard caching |
| **Storage** | 2Gi | - | Dashboard storage |

### Total Cluster Impact

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| **Pods** | 3 | 2 | -1 (vmagent removed) |
| **PVCs** | 2 | 2 | +1 (Grafana) |
| **Memory Total** | ~3.5Gi | ~4.5Gi | +1Gi |
| **ConfigMaps** | 2 | 2 | Reorganized |

---

## 8. Implementation Steps

### Phase 1: Prepare VictoriaMetrics Enhancement
1. **Create** `apps/monitoring/victoria-metrics/vmalert-rules-configmap.yaml`
2. **Update** `apps/monitoring/victoria-metrics/helmrelease.yaml` with scrape configs
3. **Update** `apps/monitoring/victoria-metrics/kustomization.yaml`
4. **Test** with `flux build kustomization apps`

### Phase 2: Create Grafana
1. **Create** `apps/monitoring/grafana/` directory
2. **Create** `apps/monitoring/grafana/kustomization.yaml`
3. **Create** `apps/monitoring/grafana/helmrelease.yaml`
4. **Create** `apps/monitoring/grafana/datasources-configmap.yaml`
5. **Create** `apps/monitoring/grafana/ingress.yaml`

### Phase 3: Update Apps Kustomization
1. **Update** `apps/kustomization.yaml` - remove vmagent/vmalert, add grafana

### Phase 4: Remove Old Components
1. **Verify** new components are working: `kubectl get hr -n monitoring`
2. **Delete** `apps/monitoring/vmagent/` directory
3. **Delete** `apps/monitoring/vmalert/` directory
4. **Commit** changes

### Phase 5: Verification
```bash
# Check all monitoring components
kubectl get hr -n monitoring
kubectl get pods -n monitoring

# Check scraping targets
curl http://victoria-metrics-single.monitoring.svc:8428/targets

# Check alerting rules
kubectl get configmap -n monitoring

# Check Grafana
kubectl get ingress -n monitoring grafana
```

---

## 9. Rollback Plan

If issues occur:

1. **Revert** git changes:
   ```bash
   git checkout HEAD~1
   git push
   ```

2. **Recreate** deleted directories:
   ```bash
   mkdir -p apps/monitoring/vmagent apps/monitoring/vmalert
   # Restore from git history
   ```

3. **Verify** restoration:
   ```bash
   flux reconcile kustomization apps --with-source
   ```

---

## 10. DNS Entries Required

Add to external-dns configuration:

| Host | Target | Purpose |
|------|--------|---------|
| `grafana.cluster.f4mily.net` | `grafana.monitoring.svc` | Grafana UI |

---

## 11. Dependencies

```
┌─────────────────────────────────────────────────────────────┐
│                    DEPLOYMENT ORDER                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. infrastructure/storage (Longhorn)                       │
│         │                                                   │
│         ▼                                                   │
│  2. infrastructure/sources (Helm Repositories)               │
│         │                                                   │
│         ▼                                                   │
│  3. apps/monitoring/victoria-metrics                        │
│         │                                                   │
│         ├──────────────────┐                                │
│         ▼                  ▼                                │
│  4. apps/monitoring/grafana                                  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 12. Summary

| Action | Count |
|--------|-------|
| **Files Created** | 6 |
| **Files Modified** | 3 |
| **Files Deleted** | 6 |
| **New HelmReleases** | 1 (Grafana) |
| **Removed HelmReleases** | 2 (vmagent, vmalert) |
| **Enhanced HelmReleases** | 1 (victoria-metrics) |

---

## 13. Post-Implementation Tasks

- [ ] Verify metrics are being scraped at `http://victoria-metrics-single:8428/targets`
- [ ] Verify alert rules are loaded at `http://victoria-metrics-single:8428/vmalert`
- [ ] Access Grafana at `https://grafana.cluster.f4mily.net`
- [ ] Configure Grafana admin password
- [ ] Import Kubernetes dashboards
- [ ] Update DNS entries for Grafana
- [ ] Test alerting notifications
