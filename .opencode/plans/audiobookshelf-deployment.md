# Audiobookshelf Deployment Plan

## Overview

Deploy [Audiobookshelf](https://audiobookshelf.org/) to the homelab cluster for managing audiobooks, podcasts, and RSS feeds.

- **Domain**: `audible.media.f4mily.net`
- **Certificate**: Use existing wildcard `*.f4mily.net` (already covers `*.media.f4mily.net` subdomain)
- **Persistence**: Longhorn for config/metadata, NFS consideration for media volumes
- **Pattern**: Follow existing HelmRelease pattern from `apps/kite` and `apps/sterling-pdf`

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Cluster (homelab)                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────────┐      ┌─────────────────────────────┐   │
│  │ cert-manager    │      │  Ingress-NGINX Controller   │   │
│  │ (infrastructure)│      │  (infrastructure)            │   │
│  └────────┬────────┘      └──────────────┬──────────────┘   │
│           │                               │                  │
│           │         wildcard-f4mily-net    │                  │
│           └───────────────┬───────────────┘                  │
│                           │                                  │
│                           ▼                                  │
│              ┌────────────────────────┐                     │
│              │  Ingress                │                     │
│              │  audible.media.f4mily  │                     │
│              └───────────┬────────────┘                     │
│                          │                                    │
│                          ▼                                    │
│              ┌────────────────────────┐                     │
│              │  audiobookshelf-svc    │                     │
│              │  (ClusterIP: 80)       │                     │
│              └───────────┬────────────┘                     │
│                          │                                    │
│           ┌──────────────┼──────────────┐                   │
│           │              │              │                   │
│           ▼              ▼              ▼                   │
│    ┌────────────┐ ┌────────────┐ ┌────────────┐           │
│    │ Config PVC │ │ Metadata   │ │ Media PVC  │           │
│    │ (Longhorn) │ │ PVC(Longhorn│ │ (NFS/Long) │           │
│    └────────────┘ └────────────┘ └────────────┘           │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Dependencies

| Dependency | Type | Status | Notes |
|------------|------|--------|-------|
| `cert-manager` | Infrastructure | ✅ Exists | `letsencrypt-production` ClusterIssuer |
| `wildcard-f4mily-net` Certificate | Infrastructure | ✅ Exists | Covers `*.f4mily.net`, but **NOT** `*.media.f4mily.net` |
| `ingress-nginx` | Infrastructure | ✅ Exists | Handles ingress routing |
| `Longhorn` | Storage | ✅ Exists | For PVC persistence |

### ⚠️ Certificate Gap

The existing wildcard certificate `wildcard-f4mily-net` only covers:
- `*.f4mily.net`
- `f4mily.net`

It does **NOT** cover `*.media.f4mily.net`. Options:

1. **Create new subdomain certificate** (recommended): Add `audible.media.f4mily.net` to existing certificate or create dedicated `media-f4mily-net` certificate
2. **Wildcard the media subdomain**: Certificate for `*.media.f4mily.net`

---

## Files to Create/Modify

### New Files

| File | Description |
|------|-------------|
| `infrastructure/network/cert-manager-issuer/media-certificate.yaml` | New Certificate for `*.media.f4mily.net` |
| `apps/audiobookshelf/namespace.yaml` | Namespace definition |
| `apps/audiobookshelf/deployment.yaml` | HelmRelease + HelmRepository |

### Modified Files

| File | Modification |
|------|--------------|
| `apps/kustomization.yaml` | Add `audiobookshelf` to resources |
| `infrastructure/network/cert-manager-issuer/kustomization.yaml` | Add new certificate resource |

---

## Kustomization Structure

```
apps/audiobookshelf/
├── kustomization.yaml      # References namespace.yaml + deployment.yaml
├── namespace.yaml          # Namespace with pod-security labels
└── deployment.yaml         # HelmRepository + HelmRelease
```

### apps/kustomization.yaml (modified)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - homepage
  - sterling-pdf
  - kite
  - audiobookshelf    # NEW
```

---

## YAML Resources

### 1. New Certificate (infrastructure/network/cert-manager-issuer/media-certificate.yaml)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-media-f4mily-net
  namespace: cert-manager
  annotations:
    kustomize.toolkit.fluxcd.io/depends-on: helm.toolkit.fluxcd.io/HelmRelease/cert-manager/cert-manager
spec:
  secretName: wildcard-media-f4mily-net-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - "*.media.f4mily.net"
    - "media.f4mily.net"
  secretTemplate:
    annotations:
      reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
```

### 2. Namespace (apps/audiobookshelf/namespace.yaml)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: audiobookshelf
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
```

### 3. HelmRelease (apps/audiobookshelf/deployment.yaml)

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: audiobookshelf-repo
  namespace: flux-system
spec:
  interval: 24h
  url: https://charts.christianhuth.de
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: audiobookshelf
  namespace: audiobookshelf
  annotations:
    kustomize.toolkit.fluxcd.io/depends-on: |
      cert-manager.io/Certificate/cert-manager/wildcard-media-f4mily-net,
      helm.toolkit.fluxcd.io/HelmRelease/ingress-nginx/ingress-nginx
spec:
  interval: 1h
  targetNamespace: audiobookshelf
  chart:
    spec:
      chart: audiobookshelf
      version: "1.7.1"
      sourceRef:
        kind: HelmRepository
        name: audiobookshelf-repo
        namespace: flux-system
  values:
    replicaCount: 1
    
    # Recreate strategy for RWO volumes
    strategy:
      type: Recreate
    
    image:
      repository: ghcr.io/audiobookshelf/audiobookshelf
      tag: "2.32.1"
      pullPolicy: IfNotPresent
    
    env:
      - name: TZ
        value: "Europe/Berlin"
    
    service:
      type: ClusterIP
      port: 80
    
    ingress:
      enabled: true
      className: nginx
      annotations:
        cert-manager.io/cluster-issuer: letsencrypt-production
        cert-manager.io/uses-release-name: "true"
        nginx.ingress.kubernetes.io/ssl-redirect: "true"
      hosts:
        - host: audible.media.f4mily.net
          paths:
            - path: /
              pathType: Prefix
      tls:
        - secretName: wildcard-media-f4mily-net-tls
          hosts:
            - audible.media.f4mily.net
    
    # Persistence for config and metadata
    persistence:
      enabled: true
      config:
        enabled: true
        type: PVC
        storageClass: longhorn
        accessMode: ReadWriteOnce
        size: 1Gi
        mountPath: /app/config
      metadata:
        enabled: true
        type: PVC
        storageClass: longhorn
        accessMode: ReadWriteOnce
        size: 1Gi
        mountPath: /app/metadata
    
    # Media volumes (optional - NFS or Longhorn)
    # Add NFS config if using network storage
    # nfs:
    #   - server: nfs.server.local
    #     storage: 100Gi
    #     name: media-nfs
    #     share:
    #       - name: audiobooks
    #         path: /audiobooks
    #         mountPath: /audiobooks
    #       - name: podcasts
    #         path: /podcasts
    #         mountPath: /podcasts
    
    # Resource limits
    resources:
      requests:
        memory: "256Mi"
        cpu: "200m"
      limits:
        memory: "1024Mi"
        cpu: "1000m"
    
    # Relaxed probes for slower startup
    livenessProbe:
      initialDelaySeconds: 60
      periodSeconds: 20
      timeoutSeconds: 10
      failureThreshold: 5
    readinessProbe:
      initialDelaySeconds: 30
      periodSeconds: 15
      timeoutSeconds: 10
      failureThreshold: 4
```

### 4. Kustomization (apps/audiobookshelf/kustomization.yaml)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
```

---

## Deployment Order

FluxCD handles this automatically via `depends-on` annotations, but logically:

1. **Infrastructure** (already deployed):
   - cert-manager
   - ingress-nginx
   - Longhorn

2. **Certificate** (new):
   - `wildcard-media-f4mily-net` Certificate

3. **Application**:
   - `audiobookshelf` HelmRelease

---

## Storage Strategy

### Option A: Longhorn Only (Simple)
```yaml
persistence:
  config:
    storageClass: longhorn
  metadata:
    storageClass: longhorn
```
- **Pros**: Simple, consistent with other apps
- **Cons**: Large media files on local Longhorn may fill disk

### Option B: NFS for Media + Longhorn for Config (Recommended for large libraries)
```yaml
persistence:
  config:
    storageClass: longhorn
  metadata:
    storageClass: longhorn
nfs:
  - server: nfs.server.local
    storage: 500Gi
    name: media-nfs
    share:
      - name: audiobooks
        path: /audiobooks
        mountPath: /audiobooks
      - name: podcasts
        path: /podcasts
        mountPath: /podcasts
```
- **Pros**: Media scales independently, Longhorn for app data only
- **Cons**: Requires NFS server

### Option C: Static NFS PVCs
If using existing NFS infrastructure:
1. Create Static PVCs in `apps/audiobookshelf/`
2. Reference in HelmRelease values

---

## Verification Checklist

After deployment:

- [ ] `kubectl get hr -n audiobookshelf` shows READY=True
- [ ] `kubectl get ingress -n audiobookshelf` exists with TLS
- [ ] Certificate `wildcard-media-f4mily-net-tls` is READY
- [ ] DNS `audible.media.f4mily.net` resolves to cluster IP
- [ ] WebUI accessible at `https://audible.media.f4mily.net`
- [ ] PVCs bound (`kubectl get pvc -n audiobookshelf`)
- [ ] Pod running without restarts

### Debug Commands

```bash
# Check HelmRelease status
kubectl get hr -n audiobookshelf
kubectl describe hr audiobookshelf -n audiobookshelf

# Check certificate
kubectl get certificate -n cert-manager
kubectl describe certificate wildcard-media-f4mily-net -n cert-manager

# Check ingress
kubectl get ingress -n audiobookshelf
kubectl describe ingress audiobookshelf -n audiobookshelf

# Logs
kubectl logs -n audiobookshelf deploy/audiobookshelf --tail=50
```

---

## Cleanup (if needed)

```bash
# Remove from Flux
flux delete kustomization apps/audiobookshelf

# Remove resources
kubectl delete namespace audiobookshelf

# Remove certificate (optional)
kubectl delete certificate wildcard-media-f4mily-net -n cert-manager

# Remove HelmRepository (if not used elsewhere)
kubectl delete helmrepository audiobookshelf-repo -n flux-system
```

---

## Notes

1. **Application Version**: Chart v1.7.1 deploys audiobookshelf v2.32.1
2. **Media Storage**: Start with Longhorn, migrate to NFS if needed
3. **First Login**: Default credentials are set on first access via web UI
4. **Mobile Apps**: Audiobookshelf has iOS/Android apps that sync with server
5. **Podcast RSS**: Add RSS feeds directly in web UI or via API

---

## References

- [Audiobookshelf Helm Chart](https://artifacthub.io/packages/helm/christianhuth/audiobookshelf)
- [Audiobookshelf Official](https://audiobookshelf.org/)
- [GitHub: advplyr/audiobookshelf](https://github.com/advplyr/audiobookshelf)
