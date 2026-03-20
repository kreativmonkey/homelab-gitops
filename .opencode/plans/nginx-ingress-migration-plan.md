# NGINX Ingress Controller Migration Plan

**Date:** 2026-03-20  
**Source:** Community ingress-nginx (kubernetes.github.io)  
**Target:** F5 NGINX Ingress Controller (ghcr.io/nginx/charts)  
**Chart Version:** 4.10.0 → 2.5.0

---

## Executive Summary

This plan documents the migration from the community-maintained `ingress-nginx` controller to the official **F5 NGINX Ingress Controller**. The migration requires updating the Helm repository reference, HelmRelease configuration, IngressClass definition, and all Ingress resources with their annotation mappings.

---

## Current State Analysis

### Files Using Ingress Annotations

| File Path | Annotations Used |
|-----------|------------------|
| `apps/homer/ingress.yaml` | `nginx.ingress.kubernetes.io/ssl-redirect` |
| `apps/homepage/ingress.yaml` | `nginx.ingress.kubernetes.io/ssl-redirect` |
| `apps/monitoring/vm-k8s-stack/ingress-victoria-metrics.yaml` | `nginx.ingress.kubernetes.io/ssl-redirect` |
| `apps/monitoring/vm-k8s-stack/ingress-grafana.yaml` | `nginx.ingress.kubernetes.io/ssl-redirect` |
| `apps/audiobookshelf/deployment.yaml` (Ingress section) | `nginx.ingress.kubernetes.io/ssl-redirect`, `nginx.ingress.kubernetes.io/proxy-body-size` |
| `apps/kite/deployment.yaml` (HelmRelease values) | `nginx.ingress.kubernetes.io/ssl-redirect` |
| `apps/sterling-pdf/deployment.yaml` (HelmRelease values) | `nginx.ingress.kubernetes.io/ssl-redirect` |
| `infrastructure/storage/ingress.yaml` | `nginx.ingress.kubernetes.io/ssl-redirect`, `nginx.ingress.kubernetes.io/proxy-body-size` |

---

## Annotation Mapping Table

| Community ingress-nginx | F5 NGINX Ingress Controller | Notes |
|------------------------|----------------------------|-------|
| `nginx.ingress.kubernetes.io/ssl-redirect` | `nginx.org/ssl-redirect` | Redirect HTTP → HTTPS |
| `nginx.ingress.kubernetes.io/proxy-body-size` | `nginx.org/client-max-body-size` | Max request body size (e.g., `1000m`) |
| `nginx.ingress.kubernetes.io/force-ssl-redirect` | `nginx.org/ssl-redirect: "true"` + server-snippet | Use `nginx.org/server-snippets` |
| `nginx.ingress.kubernetes.io/rewrite-target` | `nginx.org/rewrites` | Different syntax |
| `nginx.ingress.kubernetes.io/proxy-connect-timeout` | `nginx.org/proxy-connect-timeout` | Connection timeout |
| `nginx.ingress.kubernetes.io/proxy-send-timeout` | `nginx.org/proxy-send-timeout` | Send timeout |
| `nginx.ingress.kubernetes.io/proxy-read-timeout` | `nginx.org/proxy-read-timeout` | Read timeout |
| `nginx.ingress.kubernetes.io/limit-rps` | `nginx.org/rate-limit` | Rate limiting |
| `nginx.ingress.kubernetes.io/auth-tls-secret` | `nginx.org/client-ssl-secret` | Client SSL/TLS auth |
| `nginx.ingress.kubernetes.io/affinity` | `nginx.org/lb-method` | Load balancing affinity |
| `nginx.ingress.kubernetes.io/session-cookie-name` | `nginx.org/sticky-cookie-services` | Session cookies |
| `nginx.ingress.kubernetes.io/server-snippet` | `nginx.org/server-snippets` | Direct pass-through |
| `nginx.ingress.kubernetes.io/configuration-snippet` | `nginx.org/location-snippets` | Location-level config |
| `cert-manager.io/cluster-issuer` | `cert-manager.io/cluster-issuer` | **No change** - cert-manager annotation |
| `cert-manager.io/uses-release-name` | `cert-manager.io/uses-release-name` | **No change** - cert-manager annotation |

---

## Migration Steps

### Phase 1: Infrastructure Updates

#### 1.1 Add F5 NGINX Ingress OCI Repository

**File:** `infrastructure/sources/helm-repositories.yaml`

```yaml
# ADD THIS ENTRY (keep existing entries)
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: nginx-ingress-repo
  namespace: flux-system
spec:
  type: "oci"
  interval: 1h
  url: oci://ghcr.io/nginx/charts
```

> **Note:** OCI repositories don't use a URL in the traditional sense. The `url` field specifies the OCI registry prefix.

#### 1.2 Update IngressClass Controller

**File:** `infrastructure/sources/ingressclass.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: nginx.org/ingress-controller
```

**Changes:**
- Controller: `k8s.io/ingress-nginx` → `nginx.org/ingress-controller`

#### 1.3 Update HelmRelease

**File:** `infrastructure/network/ingress/helmrelease.yaml`

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: nginx-ingress  # Renamed from ingress-nginx
  namespace: ingress-nginx
spec:
  interval: 1h
  targetNamespace: ingress-nginx
  chart:
    spec:
      chart: nginx-ingress
      version: "2.5.0"
      sourceRef:
        kind: HelmRepository
        name: nginx-ingress-repo
        namespace: flux-system
  values:
    controller:
      kind: DaemonSet
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      priorityClassName: "homelab-infrastructure"
      service:
        type: ClusterIP
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 250m
          memory: 128Mi
      metrics:
        enabled: true
        service:
          annotations:
            prometheus.io/scrape: "true"
            prometheus.io/port: "9113"
            prometheus.io/path: "/metrics"
```

**Key Changes:**

| Property | Old Value | New Value |
|----------|-----------|-----------|
| `metadata.name` | `ingress-nginx` | `nginx-ingress` |
| `chart` | `ingress-nginx` | `nginx-ingress` |
| `chart.version` | `4.10.0` | `2.5.0` |
| `sourceRef.name` | `ingress-nginx-repo` | `nginx-ingress-repo` |
| Metrics port | `10254` | `9113` |
| Metrics path | `/metrics` | `/metrics` |

#### 1.4 Namespace Configuration

**File:** `infrastructure/sources/namespaces.yaml`

**No changes required.** The `ingress-nginx` namespace with privileged pod security labels is compatible with F5 NIC.

---

### Phase 2: Application Ingress Updates

#### 2.1 apps/homer/ingress.yaml

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: homer
  namespace: homer
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-production"
    nginx.org/ssl-redirect: "true"  # CHANGED
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - homer.f4mily.net
    - f4mily.net
    secretName: homer-tls
  rules:
  - host: homer.f4mily.net
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: homer
            port:
              number: 80
  - host: f4mily.net
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: homer
            port:
              number: 80
```

#### 2.2 apps/homepage/ingress.yaml

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: homepage
  namespace: homepage
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-production"
    nginx.org/ssl-redirect: "true"  # CHANGED
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - home.cluster.f4mily.net
    secretName: wildcard-cluster-f4mily-net-tls
  rules:
  - host: home.cluster.f4mily.net
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: homepage
            port:
              number: 80
```

#### 2.3 apps/monitoring/vm-k8s-stack/ingress-victoria-metrics.yaml

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: victoria-metrics
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
    nginx.org/ssl-redirect: "true"  # CHANGED
  labels:
    app.kubernetes.io/part-of: vm-k8s-stack
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - metrics.cluster.f4mily.net
      secretName: victoria-metrics-tls
  rules:
    - host: metrics.cluster.f4mily.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vmsingle-vm-k8s-stack
                port:
                  number: 8428
```

#### 2.4 apps/monitoring/vm-k8s-stack/ingress-grafana.yaml

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
    nginx.org/ssl-redirect: "true"  # CHANGED
  labels:
    app.kubernetes.io/part-of: vm-k8s-stack
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
                name: vm-k8s-stack-grafana
                port:
                  number: 80
```

#### 2.5 infrastructure/storage/ingress.yaml

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ui
  namespace: longhorn-system
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-production"
    nginx.org/ssl-redirect: "true"  # CHANGED
    nginx.org/client-max-body-size: "1000m"  # CHANGED
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - longhorn.cluster.f4mily.net
    secretName: wildcard-cluster-f4mily-net-tls
  rules:
  - host: longhorn.cluster.f4mily.net
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: longhorn-frontend
            port:
              number: 80
```

#### 2.6 apps/audiobookshelf/deployment.yaml

Update the Ingress section (lines 82-107):

```yaml
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: audiobookshelf
  namespace: audiobookshelf
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
    nginx.org/ssl-redirect: "true"  # CHANGED
    nginx.org/client-max-body-size: "1000m"  # CHANGED
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - audible.media.f4mily.net
      secretName: wildcard-media-f4mily-net-tls
  rules:
    - host: audible.media.f4mily.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: audiobookshelf
                port:
                  number: 80
```

#### 2.7 apps/kite/deployment.yaml

Update the ingress values section (lines 65-80):

```yaml
    ingress:
      enabled: true
      className: nginx
      annotations:
        cert-manager.io/cluster-issuer: letsencrypt-production
        cert-manager.io/uses-release-name: "true"
        nginx.org/ssl-redirect: "true"  # CHANGED
```

#### 2.8 apps/sterling-pdf/deployment.yaml

Update the ingress values section (lines 93-107):

```yaml
    ingress:
      enabled: true
      ingressClassName: nginx
      annotations:
        cert-manager.io/cluster-issuer: letsencrypt-production
        cert-manager.io/uses-release-name: "true"
        nginx.org/ssl-redirect: "true"  # CHANGED
```

---

## Zero-Downtime Migration Strategy

### Recommended Approach: Blue-Green Migration

1. **Phase A: Deploy F5 NIC alongside existing controller**
   - Do NOT remove the old ingress-nginx HelmRelease yet
   - Deploy the new F5 NIC with a different HelmRelease name
   - Both controllers will run simultaneously (minor resource increase)

2. **Phase B: Migrate Ingress annotations gradually**
   - Update one Ingress resource at a time
   - Verify functionality after each update
   - Use `flux reconcile` to trigger immediate reconciliation

3. **Phase C: Remove old controller**
   - Confirm all Ingress resources are using F5 NIC annotations
   - Delete the old ingress-nginx HelmRelease
   - Update the HelmRepository reference if desired

### Verification Steps

```bash
# Check new controller is running
kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=nginx-ingress

# Check IngressClass controller
kubectl get ingressclass nginx -o yaml

# Test a specific Ingress
kubectl describe ingress <name> -n <namespace>

# View controller logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=nginx-ingress --tail=50

# Reconcile changes
flux reconcile kustomization infrastructure --with-source
```

---

## Rollback Strategy

### If Issues Occur

1. **Quick Rollback (Git-based)**
   ```bash
   # Revert changes via Git
   git checkout HEAD~1 -- infrastructure/ apps/
   git commit -m "Revert: Rollback to community ingress-nginx"
   git push
   
   # Flux will automatically reconcile to previous state
   flux reconcile kustomization --all --with-source
   ```

2. **Manual Intervention (if needed)**
   ```bash
   # Force delete new controller
   kubectl delete hr nginx-ingress -n ingress-nginx
   
   # Recreate old HelmRelease
   kubectl apply -f - <<EOF
   apiVersion: helm.toolkit.fluxcd.io/v2
   kind: HelmRelease
   metadata:
     name: ingress-nginx
     namespace: ingress-nginx
   spec:
     chart:
       spec:
         chart: ingress-nginx
         version: "4.10.0"
   EOF
   ```

### Backup Before Migration

```bash
# Export current state
kubectl get hr ingress-nginx -n ingress-nginx -o yaml > ingress-nginx-hr-backup.yaml
kubectl get ingressclass nginx -o yaml > ingressclass-backup.yaml
kubectl get configmap -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -o yaml > ingress-nginx-configmaps-backup.yaml

# Commit backups to git (optional)
git add infrastructure/ apps/
git stash  # Stash uncommitted changes
```

---

## File Change Summary

| File | Action | Change Type |
|------|--------|-------------|
| `infrastructure/sources/helm-repositories.yaml` | **Modify** | Add OCI HelmRepository |
| `infrastructure/sources/ingressclass.yaml` | **Modify** | Update controller reference |
| `infrastructure/network/ingress/helmrelease.yaml` | **Replace** | New chart, version, values |
| `apps/homer/ingress.yaml` | **Modify** | Annotation mapping |
| `apps/homepage/ingress.yaml` | **Modify** | Annotation mapping |
| `apps/monitoring/vm-k8s-stack/ingress-victoria-metrics.yaml` | **Modify** | Annotation mapping |
| `apps/monitoring/vm-k8s-stack/ingress-grafana.yaml` | **Modify** | Annotation mapping |
| `apps/audiobookshelf/deployment.yaml` | **Modify** | Ingress annotations |
| `apps/kite/deployment.yaml` | **Modify** | HelmRelease ingress values |
| `apps/sterling-pdf/deployment.yaml` | **Modify** | HelmRelease ingress values |
| `infrastructure/storage/ingress.yaml` | **Modify** | Annotation mapping |

---

## Helm Values Structure Differences

### Community ingress-nginx → F5 NGINX Ingress

| Category | Old Path | New Path |
|----------|----------|----------|
| Replica Kind | `controller.kind` | `controller.kind` |
| Host Network | `controller.hostNetwork` | `controller.hostNetwork` |
| DNS Policy | `controller.dnsPolicy` | `controller.dnsPolicy` |
| Priority Class | `controller.priorityClassName` | `controller.priorityClassName` |
| Service Type | `controller.service.type` | `controller.service.type` |
| Resources | `controller.resources` | `controller.resources` |
| Metrics | `controller.metrics.enabled` | `controller.metrics.enabled` |
| Metrics Port | `controller.metrics.service.port` | `controller.metrics.port` |

**Note:** The F5 NIC uses port `9113` for metrics by default (different from community's `10254`).

---

## Post-Migration Checklist

- [ ] Verify all Ingress resources have F5 NIC annotations
- [ ] Confirm controller pods are running (`kubectl get pods -n ingress-nginx`)
- [ ] Test HTTPS access to all services
- [ ] Check controller logs for annotation warnings
- [ ] Verify metrics are being scraped (port 9113)
- [ ] Update any monitoring dashboards if needed
- [ ] Test file upload functionality (audiobookshelf, sterling-pdf)
- [ ] Remove old HelmRepository reference (optional)
- [ ] Commit all changes to Git

---

## Additional Resources

- [F5 NGINX Ingress Controller Documentation](https://docs.nginx.com/nginx-ingress-controller/)
- [Helm Chart Repository](https://github.com/nginxinc/charts)
- [Annotation Reference](https://docs.nginx.com/nginx-ingress-controller/configuration/ingress-resources/advanced-configuration-with-annotations/)
- [OCI Registry](https://ghcr.io/nginx/charts)

