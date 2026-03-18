# VictoriaMetrics Comprehensive Monitoring Implementation Plan

## 1. Current VictoriaMetrics Status

### Deployment Details
- **HelmRelease**: `infrastructure/observability/helmrelease.yaml`
- **Namespace**: `monitoring`
- **Chart**: `victoria-metrics-single` v0.33.0
- **vmagent**: Enabled (required for ServiceMonitor scraping)
- **Resources**: CPU 50m-250m, Memory 256Mi-512Mi

### Existing ServiceMonitors
The file `infrastructure/observability/servicemonitor.yaml` contains ServiceMonitors for:
- ingress-nginx
- cert-manager
- external-dns

**CRITICAL ISSUE**: The `servicemonitor.yaml` is NOT included in the kustomization!

### CloudNativePG ServiceMonitor
- **Location**: `infrastructure/database/cnpg/servicemonitor.yaml`
- **Status**: Exists but missing dependency annotation
- **Monitoring enabled**: Yes (in cluster.yaml: `monitoring.enabled: true`)

---

## 2. Components Requiring ServiceMonitors

### Already Monitored (Requires Verification/Fixes)
| Component | Namespace | ServiceMonitor Exists | Status |
|-----------|-----------|----------------------|--------|
| ingress-nginx | ingress-nginx | Yes | **BROKEN** - metrics disabled in HelmRelease |
| cert-manager | cert-manager | Yes | Verify labels/ports |
| external-dns | external-dns | Yes | Verify labels/ports |
| CloudNativePG | cnpg-system | Yes | Missing depends-on annotation |

### Needs New ServiceMonitors
| Component | Namespace | Metrics Port | Notes |
|-----------|-----------|---------------|-------|
| Velero | velero | 8085 | Default metrics port |
| ingress-nginx | ingress-nginx | 10254 | After enabling metrics |

### Apps (Do Not Expose Metrics - No Action Required)
| App | Namespace | Metrics | Action |
|-----|-----------|---------|--------|
| homer | homer | No | Static dashboard, no metrics endpoint |
| kite | kite | Unknown | Need to verify chart documentation |
| sterling-pdf | sterling-pdf | Unknown | Need to verify chart documentation |

---

## 3. Required Changes

### A. Fix Observability Kustomization (CRITICAL)
**File**: `infrastructure/observability/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
  - ingress.yaml
  - servicemonitor.yaml  # ADD THIS LINE
```

### B. Enable ingress-nginx Metrics
**File**: `infrastructure/network/ingress/helmrelease.yaml`

Change:
```yaml
controller:
  metrics:
    enabled: false
```

To:
```yaml
controller:
  metrics:
    enabled: true
    service:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "10254"
        prometheus.io/path: "/metrics"
```

### C. Fix CloudNativePG ServiceMonitor Dependencies
**File**: `infrastructure/database/cnpg/servicemonitor.yaml`

Add annotation:
```yaml
metadata:
  annotations:
    kustomize.toolkit.fluxcd.io/depends-on: helm.toolkit.fluxcd.io/HelmRelease/monitoring/vm
```

### D. Add Velero ServiceMonitor
**New File**: `infrastructure/backup/servicemonitor.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: velero
  namespace: monitoring
  labels:
    release: victoriametrics
  annotations:
    kustomize.toolkit.fluxcd.io/depends-on: helm.toolkit.fluxcd.io/HelmRelease/monitoring/vm
spec:
  endpoints:
    - port: http
      interval: 30s
  namespaceSelector:
    matchNames:
      - velero
  selector:
    app.kubernetes.io/name: velero
```

### E. Add Velero Service (Required for ServiceMonitor)
**File**: `infrastructure/backup/helmrelease.yaml`

Add to values:
```yaml
metrics:
  enabled: true
  service:
    annotations:
      prometheus.io/scrape: "true"
      prometheus.io/port: "8085"
```

---

## 4. ServiceMonitor Configurations Summary

### File: `infrastructure/observability/servicemonitor.yaml` (Update)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ingress-nginx
  namespace: monitoring
  labels:
    release: victoriametrics
  annotations:
    kustomize.toolkit.fluxcd.io/depends-on: helm.toolkit.fluxcd.io/HelmRelease/monitoring/vm
spec:
  endpoints:
    - port: metrics
      interval: 30s
  namespaceSelector:
    matchNames:
      - ingress-nginx
  selector:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/component: controller
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cert-manager
  namespace: monitoring
  labels:
    release: victoriametrics
  annotations:
    kustomize.toolkit.fluxcd.io/depends-on: helm.toolkit.fluxcd.io/HelmRelease/monitoring/vm
spec:
  endpoints:
    - port: tcp-webhook
      interval: 30s
    - port: http
      interval: 30s
  namespaceSelector:
    matchNames:
      - cert-manager
  selector:
    app.kubernetes.io/name: cert-manager
    app.kubernetes.io/component: controller
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: external-dns
  namespace: monitoring
  labels:
    release: victoriametrics
  annotations:
    kustomize.toolkit.fluxcd.io/depends-on: helm.toolkit.fluxcd.io/HelmRelease/monitoring/vm
spec:
  endpoints:
    - port: http
      interval: 30s
  namespaceSelector:
    matchNames:
      - external-dns
  selector:
    app.kubernetes.io/name: external-dns
```

### File: `infrastructure/database/cnpg/servicemonitor.yaml` (Update)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cloudnative-pg
  namespace: monitoring
  labels:
    release: victoriametrics
  annotations:
    kustomize.toolkit.fluxcd.io/depends-on: helm.toolkit.fluxcd.io/HelmRelease/monitoring/vm
spec:
  endpoints:
    - port: metrics
      interval: 30s
  namespaceSelector:
    matchNames:
      - cnpg-system
  selector:
    app.kubernetes.io/name: cloudnative-pg
```

### File: `infrastructure/backup/servicemonitor.yaml` (New)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: velero
  namespace: monitoring
  labels:
    release: victoriametrics
  annotations:
    kustomize.toolkit.fluxcd.io/depends-on: helm.toolkit.fluxcd.io/HelmRelease/monitoring/vm
spec:
  endpoints:
    - port: http
      interval: 30s
  namespaceSelector:
    matchNames:
      - velero
  selector:
    app.kubernetes.io/name: velero
```

---

## 5. Implementation Order

1. **Step 1**: Update `infrastructure/observability/kustomization.yaml` - Include servicemonitor.yaml
2. **Step 2**: Update `infrastructure/network/ingress/helmrelease.yaml` - Enable metrics
3. **Step 3**: Update `infrastructure/observability/servicemonitor.yaml` - Fix annotations
4. **Step 4**: Update `infrastructure/database/cnpg/servicemonitor.yaml` - Add depends-on annotation
5. **Step 5**: Update `infrastructure/backup/helmrelease.yaml` - Enable metrics
6. **Step 6**: Create `infrastructure/backup/servicemonitor.yaml` - New Velero ServiceMonitor
7. **Step 7**: Add `servicemonitor.yaml` to `infrastructure/backup/kustomization.yaml`

---

## 6. Files to Modify

| File | Action |
|------|--------|
| `infrastructure/observability/kustomization.yaml` | Add servicemonitor.yaml to resources |
| `infrastructure/network/ingress/helmrelease.yaml` | Enable metrics (set `controller.metrics.enabled: true`) |
| `infrastructure/observability/servicemonitor.yaml` | Add depends-on annotations |
| `infrastructure/database/cnpg/servicemonitor.yaml` | Add depends-on annotation |
| `infrastructure/backup/helmrelease.yaml` | Enable metrics |
| `infrastructure/backup/kustomization.yaml` | Add servicemonitor.yaml to resources |

---

## 7. Files to Create

| File | Description |
|------|-------------|
| `infrastructure/backup/servicemonitor.yaml` | Velero ServiceMonitor |

---

## 8. Verification Commands

After implementation, verify with:

```bash
# Check ServiceMonitor status
kubectl get servicemonitor -n monitoring

# Check vmagent targets
kubectl get podlogs -n monitoring -l app.kubernetes.io/name=victoria-metrics

# Check for discovered targets
curl -s http://<vm-agent>:8429/api/v1/targets | jq

# Verify all metrics endpoints are reachable
kubectl get endpoints -A | grep -E "(metrics|http)"
```

---

## 9. Notes

- **homer**: Does not expose metrics (static React dashboard). No ServiceMonitor needed.
- **kite/sterling-pdf**: These are Helm charts. Check if they expose metrics via:
  - `values.yaml` - look for `metrics.enabled` or similar
  - If they don't expose metrics natively, consider adding a sidecar exporter
- **ingress-nginx**: The current helmrelease has metrics DISABLED - this must be fixed for monitoring to work
- **All ServiceMonitors**: Must have `release: victoriametrics` label for vmagent to scrape them
- **All ServiceMonitors**: Must have depends-on annotation pointing to the VM HelmRelease

