# Homepage Replacement Plan

## Overview

Replace the existing homer dashboard with [Homepage](https://gethomepage.dev/) to leverage:
- Built-in Kubernetes widget for auto-discovery
- Better container state monitoring
- Modern UI with service status indicators
- YAML-based configuration (GitOps-friendly)

## Current State Analysis

### Existing Homer Deployment
- **Namespace**: `homer`
- **Image**: `b4bz/homer:v25.11.1`
- **Domain**: `homer.f4mily.net`, `f4mily.net`
- **Config**: Static ConfigMap with hardcoded services

### Cluster Applications to Include
| Service | Namespace | Domain | Source |
|---------|-----------|--------|--------|
| Monitoring | monitoring | monitoring.cluster.f4mily.net | infrastructure/observability/ingress.yaml |
| Kite | kite | kite.f4mily.net | apps/kite |
| Sterling PDF | sterling-pdf | sterling-pdf.f4mily.net | apps/sterling-pdf |

---

## Target Directory Structure

```
apps/homepage/
├── kustomization.yaml
├── namespace.yaml
├── helmrelease.yaml
├── configmap.yaml
└── ingress.yaml (optional - homepage handles via Helm values)
```

---

## New YAML Resources

### 1. Namespace (namespace.yaml)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: homepage
  labels:
    app.kubernetes.io/name: homepage
    app.kubernetes.io/instance: homepage
```

### 2. HelmRepository (in helmrelease.yaml)

Add to existing flux-system or create dedicated repository:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: homepage-repo
  namespace: flux-system
spec:
  interval: 24h
  url: https://homepage.gitlab.io/charts
```

### 3. HelmRelease (helmrelease.yaml)

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: homepage
  namespace: homepage
spec:
  interval: 1h
  targetNamespace: homepage
  chart:
    spec:
      chart: homepage
      version: "1.0.0"
      sourceRef:
        kind: HelmRepository
        name: homepage-repo
        namespace: flux-system
  values:
    image:
      repository: ghcr.io/benphelps/homepage
      tag: "latest"
      pullPolicy: Always
    
    env:
      - name: PUID
        value: "1000"
      - name: PGID
        value: "1000"
      - name: TZ
        value: "Europe/Berlin"
    
    # Enable Kubernetes widget
    configHash: 
      enabled: true
    
    # Service configuration
    service:
      type: ClusterIP
      port: 3000
    
    # Ingress via Helm values (recommended for homepage)
    ingress:
      enabled: true
      className: nginx
      annotations:
        cert-manager.io/cluster-issuer: letsencrypt-production
        nginx.ingress.kubernetes.io/ssl-redirect: "true"
      hosts:
        - host: home.cluster.f4mily.net
          paths:
            - path: /
              pathType: Prefix
      tls:
        - secretName: homepage-tls
          hosts:
            - home.cluster.f4mily.net
    
    # Resource limits for infrastructure priority
    resources:
      limits:
        cpu: 500m
        memory: 256Mi
      requests:
        cpu: 100m
        memory: 128Mi
    
    # Priority class
    priorityClassName: homelab-infrastructure
```

### 4. Homepage Configuration (configmap.yaml)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: homepage-config
  namespace: homepage
data:
  config.yaml: |
    # Homepage Configuration
    # Documentation: https://gethomepage.dev/latest/configs/
    
    language: "de"
    title: "Homelab Dashboard"
    
    # Header configuration
    header:
      # Left side
      left:
        - search:
            provider: duckduckgo
            focus: true
      # Right side
      right:
        - clock:
            format: "HH:mm"
            dateFormat: "DD.MM.YYYY"
        - kubernetes:
            clusterName: homelab
            showCluster: true
    
    # Kubernetes Widget Configuration
    kubernetes:
      mode: cluster
      refreshInterval: 30000
    
    # Service Definitions
    services:
      # Infrastructure Section
      - name: Infrastructure
        icon: mdi:server-network
        items:
          - name: Monitoring
            description: VictoriaMetrics Dashboard
            icon: mdi:chart-line
            href: "https://monitoring.cluster.f4mily.net"
            external: true
            provider: kubernetes
            namespace: monitoring
            service: monitoring-vm-victoria-metrics-single-server
            port: 8428
          
          - name: Kite
            description: Kubernetes Dashboard
            icon: mdi:kubernetes
            href: "https://kite.f4mily.net"
            external: true
            provider: kubernetes
            namespace: kite
            service: kite
            port: 8080
          
          - name: Sterling PDF
            description: PDF Tools
            icon: mdi:file-document-outline
            href: "https://sterling-pdf.f4mily.net"
            external: true
            provider: kubernetes
            namespace: sterling-pdf
            service: sterling-pdf
            port: 8080
    
    # Widgets (right side panels)
    widgets:
      # Resource usage
      - resources:
          expanded: true
          cpuColor: "green"
          memoryColor: "blue"
          diskColor: "yellow"
      
      # Kubernetes cluster status
      - kubernetes:
          showCluster: true
          showContainers: true
          showNodes: true
          showPods: true
          showVolumes: false
      
      # Service status (auto-discovery)
      - services:
          filter:
            - namespace: monitoring
            - namespace: kite
            - namespace: sterling-pdf
          showStatus: true
      
      # Docker containers status
      - container:
          expanded: false
          cpu: true
          memory: true
          network: false
          disk: false
```

---

## Icon Selections

Based on homepage's icon system (Material Design Icons - mdi):

| Service | Icon | Code |
|---------|------|------|
| Monitoring | Chart Line | `mdi:chart-line` |
| Kite | Kubernetes | `mdi:kubernetes` |
| Sterling PDF | File Document | `mdi:file-document-outline` |
| Longhorn (future) | Database | `mdi:database` |
| Traefik (future) | Router | `mdi:router` |

---

## Dependencies & Prerequisites

### 1. Cert-Manager Certificate
Must exist before homepage ingress:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: homepage-tls
  namespace: homepage
spec:
  secretName: homepage-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - home.cluster.f4mily.net
```

### 2. FluxCD Dependencies

The homepage HelmRelease should depend on:
- `cert-manager` (for TLS certificate)
- `ingress-nginx` (for ingress controller)

```yaml
metadata:
  annotations:
    kustomize.toolkit.fluxcd.io/depends-on: |
      cert-manager.io/Certificate/cert-manager/wildcard-f4mily-net,
      helm.toolkit.fluxcd.io/HelmRelease/ingress-nginx/ingress-nginx
```

### 3. HelmRepository Requirement

Add to `infrastructure/sources/` if not already present:

```yaml
# infrastructure/sources/homepage.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: homepage-repo
  namespace: flux-system
spec:
  interval: 24h
  url: https://homepage.gitlab.io/charts
```

---

## Migration Steps

### Phase 1: Preparation
1. Create `apps/homepage/` directory
2. Add HelmRepository for homepage chart
3. Create namespace, HelmRelease, and ConfigMap

### Phase 2: Testing
1. Apply changes without ingress TLS (use staging or disable TLS temporarily)
2. Verify Kubernetes widget discovers services
3. Verify all links work correctly
4. Test responsive design

### Phase 3: Cutover
1. Enable TLS on ingress
2. Update DNS if needed
3. Remove old homer deployment:
   ```bash
   flux delete kustomization apps/homer
   kubectl delete namespace homer
   ```
4. Update `apps/kustomization.yaml`:
   ```yaml
   resources:
     - homepage  # Replace homer
     - sterling-pdf
     - kite
   ```

### Phase 4: Post-Migration
1. Remove `apps/homer/` directory
2. Verify metrics are being collected
3. Test auto-discovery after deploying new services

---

## Files to Create/Modify

### New Files
| File | Description |
|------|-------------|
| `apps/homepage/namespace.yaml` | Namespace definition |
| `apps/homepage/helmrelease.yaml` | Homepage HelmRelease |
| `apps/homepage/configmap.yaml` | Homepage configuration |
| `infrastructure/sources/homepage.yaml` | HelmRepository |

### Modified Files
| File | Modification |
|------|--------------|
| `apps/kustomization.yaml` | Replace homer with homepage |

### Deleted Files (after migration)
| File | Reason |
|------|--------|
| `apps/homer/namespace.yaml` | Replaced by homepage |
| `apps/homer/deployment.yaml` | Replaced by HelmRelease |
| `apps/homer/service.yaml` | Managed by Helm chart |
| `apps/homer/ingress.yaml` | Managed by Helm values |
| `apps/homer/configmap.yaml` | Replaced by new configmap |
| `apps/homer/kustomization.yaml` | Directory removed |

---

## Homepage Kubernetes Widget

The Kubernetes widget provides automatic discovery:

### Auto-Discovery Configuration

```yaml
kubernetes:
  mode: cluster
  refreshInterval: 30000
  clusters:
    - name: homelab
      url: "https://kubernetes.default.svc"
      tokenSecret: 
        name: homepage-kubeconfig
        key: token
```

### RBAC Requirements

Homepage needs read access to the Kubernetes API:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: homepage-read
  namespace: homepage
rules:
  - apiGroups: [""]
    resources: ["services", "pods", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: homepage-read
  namespace: homepage
subjects:
  - kind: ServiceAccount
    name: default
    namespace: homepage
roleRef:
  kind: Role
  name: homepage-read
  apiGroup: rbac.authorization.k8s.io
```

Note: For cluster-wide access, use ClusterRole instead of Role.

---

## Verification Checklist

- [ ] HelmRepository created and synced
- [ ] HelmRelease deployed successfully
- [ ] Homepage pod running and healthy
- [ ] Ingress created with TLS
- [ ] DNS resolves to homepage
- [ ] Kubernetes widget shows cluster status
- [ ] All service links functional
- [ ] Old homer removed
- [ ] ConfigMap correctly configured

---

## Known Issues / Considerations

1. **Kubernetes Widget**: Requires proper RBAC - may need ClusterRole for full auto-discovery
2. **External Links**: Homepage treats external links differently - use `external: true` for services outside homepage
3. **Auto-Refresh**: Set appropriate `refreshInterval` to avoid API rate limiting
4. **Icons**: Use Material Design Icons (mdi:) prefix for built-in icons
5. **Timezone**: Configure TZ environment variable for clock widget accuracy
