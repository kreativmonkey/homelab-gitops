# Nginx-Ingress Migration Integration Test Report

**Test Date:** 2026-03-20  
**Test Scope:** nginx-ingress migration from kubernetes/ingress-nginx to nginx-inc/ingress  
**Agent:** @integration-test  

---

## Executive Summary

| Status | Paths Tested | Passed | Failed | Warnings |
|--------|-------------|--------|--------|----------|
| **FAIL** | 9 | 6 | 3 | Multiple |

**Critical Issues Found:** 3  
**Action Items:** 5

---

## Detailed Test Results

### 1. infrastructure/sources/

| Field | Value |
|-------|-------|
| **Command Used** | `kubectl kustomize infrastructure/sources/` |
| **Result** | ⚠️ **KUSTOMIZE BUILD: PASS** |
| **Server-Side Dry-Run** | ❌ **FAIL** |

**Kustomize Build Output:**
- All Namespaces created correctly (cert-manager, external-dns, ingress-nginx, longhorn-system, monitoring)
- IngressClass `nginx` defined with controller `nginx.org/ingress-controller`
- All HelmRepositories present (authentik, cnpg, external-dns, hetzner-webhook, ingress-nginx, jetstack, longhorn, metrics-server, prometheus-community, velero, victoriametrics)
- OCIRepository `nginx-inc-ingress-repo` created with tag `2.5.0`

**Server-Side Dry-Run Errors:**
```
1. OCIRepository CRD not recognized by cluster (apiVersion mismatch)
2. IngressClass.networking.k8s.io "nginx" is invalid: spec.controller: Invalid value: "nginx.org/ingress-controller": field is immutable
3. HelmRelease.helm.toolkit.fluxcd.io "nginx-ingress" is invalid: spec.chart.spec.sourceRef.kind: Unsupported value: "OCIRepository": supported values: "HelmRepository", "GitRepository", "Bucket"
```

**Cluster Environment:**
- FluxCD Version: v2.8.2
- helm-controller: v1.5.2
- kustomize-controller: v1.8.2
- HelmRepository CRD versions: v1

**Root Cause Analysis:**
1. The cluster's helm-controller v1.5.2 does NOT support `OCIRepository` as a valid `sourceRef.kind` for HelmRelease
2. The IngressClass controller field is immutable in Kubernetes - cannot change from `k8s.io/ingress-nginx` to `nginx.org/ingress-controller`

---

### 2. infrastructure/network/ingress/

| Field | Value |
|-------|-------|
| **Command Used** | `kubectl kustomize infrastructure/network/ingress/` |
| **Result** | ✅ **KUSTOMIZE BUILD: PASS** |
| **Server-Side Dry-Run** | ❌ **FAIL** |

**Kustomize Build Output:**
- HelmRelease `nginx-ingress` correctly references OCIRepository source
- ServiceMonitor for Prometheus metrics configured correctly
- Values file uses `nginx.org` annotations (client-max-body-size, ssl-redirect)

**Server-Side Dry-Run Errors:**
```
1. HelmRelease sourceRef.kind "OCIRepository" not supported (see above)
2. ServiceMonitor CRD not found in cluster
```

**Action Items:**
- Upgrade FluxCD to v0.36+ for OCIRepository support in HelmRelease
- Install prometheus-operator CRDs for ServiceMonitor

---

### 3. infrastructure/storage/

| Field | Value |
|-------|-------|
| **Command Used** | `kubectl kustomize infrastructure/storage/` |
| **Result** | ✅ **KUSTOMIZE BUILD: PASS** |
| **Server-Side Dry-Run** | ✅ **PASS** (with warnings) |

**Notes:**
- Longhorn HelmRelease configured correctly
- Ingress annotations updated to `nginx.org/*` format
- All resources validated against cluster API

**Warnings:**
- Missing `kubectl.kubernetes.io/last-applied-configuration` annotation on namespace resources (non-blocking)

---

### 4. apps/homer/

| Field | Value |
|-------|-------|
| **Command Used** | `kubectl kustomize apps/homer/` |
| **Result** | ✅ **KUSTOMIZE BUILD: PASS** |
| **Server-Side Dry-Run** | ⚠️ **PARTIAL PASS** |

**Notes:**
- All manifests generated correctly
- Ingress uses `nginx.org/ssl-redirect: "true"` annotation
- Deployment, Service, ConfigMap, and Ingress all present

**Warning:**
- Namespace creation race condition (resources depend on namespace creation order)

---

### 5. apps/homepage/

| Field | Value |
|-------|-------|
| **Command Used** | `kubectl kustomize apps/homepage/` |
| **Result** | ✅ **KUSTOMIZE BUILD: PASS** |
| **Server-Side Dry-Run** | ✅ **PASS** (with warnings) |

**Notes:**
- Namespace already exists - configured successfully
- All resources (ConfigMap, Service, Deployment, Ingress) validated
- Ingress annotation `nginx.org/ssl-redirect: "true"` correct

---

### 6. apps/audiobookshelf/

| Field | Value |
|-------|-------|
| **Command Used** | `kubectl kustomize apps/audiobookshelf/` |
| **Result** | ✅ **KUSTOMIZE BUILD: PASS** |
| **Server-Side Dry-Run** | ✅ **PASS** (with warnings) |

**Notes:**
- All resources validated successfully
- Ingress uses both `nginx.org/ssl-redirect` and `nginx.org/client-max-body-size: 1000m` annotations
- Health checks and resource limits configured correctly

---

### 7. apps/kite/

| Field | Value |
|-------|-------|
| **Command Used** | `kubectl kustomize apps/kite/` |
| **Result** | ✅ **KUSTOMIZE BUILD: PASS** |
| **Server-Side Dry-Run** | ✅ **PASS** (with warnings) |

**Notes:**
- HelmRelease and HelmRepository created successfully
- Ingress uses `nginx.org/ssl-redirect: "true"` annotation
- Dependencies annotation present for cert-manager Certificate

---

### 8. apps/sterling-pdf/

| Field | Value |
|-------|-------|
| **Command Used** | `kubectl kustomize apps/sterling-pdf/` |
| **Result** | ✅ **KUSTOMIZE BUILD: PASS** |
| **Server-Side Dry-Run** | ✅ **PASS** (with warnings) |

**Notes:**
- HelmRelease and HelmRepository created successfully
- Ingress uses `nginx.org/ssl-redirect: "true"` annotation
- SOPS-encrypted credentials secret present

---

### 9. apps/monitoring/vm-k8s-stack/

| Field | Value |
|-------|-------|
| **Command Used** | `kubectl kustomize apps/monitoring/vm-k8s-stack/` |
| **Result** | ✅ **KUSTOMIZE BUILD: PASS** |
| **Server-Side Dry-Run** | ❌ **FAIL** |

**Kustomize Build Output:**
- vm-k8s-stack HelmRelease configured correctly
- Grafana and VictoriaMetrics Ingress resources present
- All nginx.org annotations correct

**Server-Side Dry-Run Error:**
```
error validating data: unexpected GroupVersion string: ENC[AES256_GCM,...]
```
**Cause:** SOPS-encrypted secret causing kubectl validation to fail (decryption not applied during dry-run)

**Note:** This is expected behavior - kubectl cannot validate encrypted secrets without decryption.

---

## Critical Issues Summary

### Issue #1: IngressClass Controller Field Immutable
**Severity:** 🔴 **CRITICAL**  
**Location:** `infrastructure/sources/ingress-class.yaml`  

**Problem:**
The existing IngressClass `nginx` has controller `k8s.io/ingress-nginx`. Kubernetes IngressClass resources have an immutable `spec.controller` field. The migration attempts to change it to `nginx.org/ingress-controller`, which causes an API rejection.

**Current State:**
```yaml
spec:
  controller: k8s.io/ingress-nginx  # Existing - cannot change
```

**Required State:**
```yaml
spec:
  controller: nginx.org/ingress-controller  # Migration target
```

**Solution Options:**
1. **Delete and recreate IngressClass** (requires coordinated downtime)
2. **Create new IngressClass with different name** (e.g., `nginx-inc`) and make it default
3. **Keep existing ingress-nginx and run both controllers** (dual ingress approach)

---

### Issue #2: HelmRelease OCIRepository SourceRef Unsupported
**Severity:** 🔴 **CRITICAL**  
**Location:** `infrastructure/network/ingress/helmrelease.yaml`  

**Problem:**
The cluster's helm-controller v1.5.2 does not support `OCIRepository` as a valid `sourceRef.kind` for HelmRelease resources. The HelmRelease CRD only accepts:
- `HelmRepository`
- `GitRepository`
- `Bucket`

**Error:**
```
spec.chart.spec.sourceRef.kind: Unsupported value: "OCIRepository": supported values: "HelmRepository", "GitRepository", "Bucket"
```

**Solution Options:**
1. **Upgrade FluxCD** to v0.36+ (helm-controller v0.38+) which adds OCIRepository support
2. **Use HelmRepository** instead of OCIRepository (if nginx-inc provides a HelmRepository)

---

### Issue #3: Missing Prometheus Operator CRDs
**Severity:** 🟡 **MEDIUM**  
**Location:** `infrastructure/network/ingress/servicemonitor.yaml`  

**Problem:**
ServiceMonitor CRD (`monitoring.coreos.com/v1`) is not installed in the cluster. This causes the ServiceMonitor resource to fail validation.

**Solution:**
Install prometheus-operator CRDs or use alternative metrics scraping approach.

---

## Flux Dependency Tree Validation

**Command:** `flux tree kustomization infra-sources -n flux-system`

**Result:** ✅ **PASS**

```
Kustomization/flux-system/infra-sources
├── Namespace/cert-manager
├── Namespace/external-dns
├── Namespace/ingress-nginx
├── Namespace/longhorn-system
├── Namespace/monitoring
├── PriorityClass/homelab-infrastructure
├── IngressClass/nginx
├── Secret/cert-manager/hetzner-api-token-secret
├── Secret/external-dns/hetzner-api-token
├── HelmRepository/flux-system/authentik-repo
├── HelmRepository/flux-system/cnpg-repo
├── HelmRepository/flux-system/external-dns-repo
├── HelmRepository/flux-system/hetzner-webhook-repo
├── HelmRepository/flux-system/ingress-nginx-repo
├── HelmRepository/flux-system/jetstack-repo
├── HelmRepository/flux-system/longhorn-repo
├── HelmRepository/flux-system/metrics-server-repo
├── HelmRepository/flux-system/prometheus-community-repo
├── HelmRepository/flux-system/velero-repo
└── HelmRepository/flux-system/victoriametrics-repo
```

**Note:** The dependency tree shows all resources but does NOT include the new OCIRepository because it's in the YAML files but not yet applied due to CRD limitations.

---

## Action Items for @k8s-specialist

| Priority | Action Item | Affected Files |
|----------|-------------|----------------|
| **P0** | Resolve IngressClass controller immutability - delete and recreate or use new name | `infrastructure/sources/ingress-class.yaml` |
| **P0** | Upgrade FluxCD to v0.36+ for OCIRepository HelmRelease support | Cluster upgrade required |
| **P1** | Install prometheus-operator CRDs for ServiceMonitor | `infrastructure/network/ingress/servicemonitor.yaml` |
| **P2** | Validate nginx-inc HelmRepository availability as alternative to OCIRepository | `infrastructure/network/ingress/helmrelease.yaml` |
| **P2** | Test SOPS decryption during kubectl dry-run | N/A - expected behavior |

---

## Annotation Validation

All ingress resources were validated for correct nginx.org annotations:

| Path | ssl-redirect | client-max-body-size | className | Status |
|------|--------------|----------------------|-----------|--------|
| infrastructure/storage/ | ✅ `nginx.org/ssl-redirect: "true"` | ✅ `nginx.org/client-max-body-size: 1000m` | N/A | ✅ PASS |
| apps/homer/ | ✅ `nginx.org/ssl-redirect: "true"` | ❌ Missing | ✅ `ingressClassName: nginx` | ⚠️ WARN |
| apps/homepage/ | ✅ `nginx.org/ssl-redirect: "true"` | ❌ Missing | ✅ `ingressClassName: nginx` | ⚠️ WARN |
| apps/audiobookshelf/ | ✅ `nginx.org/ssl-redirect: "true"` | ✅ `nginx.org/client-max-body-size: 1000m` | ✅ `ingressClassName: nginx` | ✅ PASS |
| apps/kite/ | ✅ `nginx.org/ssl-redirect: "true"` | ❌ Missing | ✅ `className: nginx` | ⚠️ WARN |
| apps/sterling-pdf/ | ✅ `nginx.org/ssl-redirect: "true"` | ❌ Missing | ✅ `ingressClassName: nginx` | ⚠️ WARN |
| apps/monitoring/vm-k8s-stack/ | ✅ `nginx.org/ssl-redirect: "true"` | ❌ Missing | ✅ `ingressClassName: nginx` | ⚠️ WARN |

**Note:** Missing `client-max-body-size` is not necessarily an error - it depends on application requirements. Longhorn UI and Audiobookshelf specifically require larger body sizes.

---

## Conclusion

**Status: FAIL - Blocking Issues Found**

The nginx-ingress migration cannot proceed as-is due to two critical cluster compatibility issues:

1. **IngressClass immutability** prevents changing the controller from kubernetes/ingress-nginx to nginx-inc/ingress
2. **FluxCD version limitation** prevents using OCIRepository as HelmRelease sourceRef

### Recommendations:

1. **Immediate:** Upgrade FluxCD to v0.36+ on the cluster
2. **Immediate:** Coordinate IngressClass recreation (requires brief downtime or new IngressClass name)
3. **Testing:** Validate nginx-inc/ingress chart works with existing IngressClass controller name (unlikely to work)

---

*Report generated by @integration-test agent*  
*Workspace: /home/sebastian/git/github.com/gitops-homelab*
