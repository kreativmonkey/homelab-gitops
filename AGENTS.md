# AGENTS.md - Agent Coding Guidelines

This document provides guidelines for AI agents operating in this repository.

## Project Overview

This is a **Kubernetes GitOps homelab** using FluxCD to manage infrastructure on Talos Linux. The repository contains:
- **Infrastructure**: cert-manager, ingress-nginx, external-dns, Longhorn, VictoriaMetrics
- **Applications**: homer, kite, sterling-pdf
- **Secrets**: Managed with SOPS + age encryption

## Directory Structure

```
clusters/homelab/     # FluxCD entry points
infrastructure/       # Core cluster components (base, sources, storage, network, observability)
apps/                 # User applications
```

## Essential Commands

### FluxCD Reconciliation
```bash
# Reconcile all kustomizations
flux reconcile kustomization --all --with-source

# Reconcile specific kustomization
flux reconcile kustomization infrastructure --with-source
flux reconcile kustomization apps --with-source

# Check kustomization status
kubectl get kustomization -A

# View kustomize-controller logs
kubectl logs -n flux-system deploy/kustomize-controller --tail=50
```

### Helm Releases
```bash
# Check HelmRelease status
kubectl get hr -A

# Debug HelmRelease
kubectl describe hr <name> -n <namespace>
```

### Secret Management (SOPS)
```bash
# Decrypt a secret for viewing
sops -d <file>.yaml

# Edit a secret
sops <file>.yaml

# Create new encrypted secret
kubectl create secret generic <name> --from-literal=key=value --dry-run=client -o yaml | \
  sops --encrypt --age $(cat ~/.config/sops/age/keys.txt | grep -oP "public key: \K(.*)") --in-place <file>.yaml
```

### Testing Kustomize Builds
```bash
# Test kustomize build locally
flux build kustomization <name> --path ./<path>

# Tree kustomization dependencies
flux tree kustomization <name>
```

## Code Style Guidelines

### YAML Structure

#### Indentation
- Use **2 spaces** for indentation (no tabs)
- Align keys within the same resource

#### Resource Ordering
1. `apiVersion` + `kind`
2. `metadata` (name, namespace, labels, annotations)
3. `spec` (top-level)
4. Nested keys in alphabetical order within sections

#### Example
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: external-dns
  namespace: external-dns
spec:
  chart:
    spec:
      chart: external-dns
      version: "1.20.0"
      sourceRef:
        kind: HelmRepository
        name: external-dns-repo
        namespace: flux-system
  interval: 1h
  targetNamespace: external-dns
  values:
    provider:
      name: webhook
```

### Naming Conventions

- **Resources**: lowercase with hyphens (e.g., `external-dns`, `cert-manager`)
- **Namespaces**: lowercase with hyphens (e.g., `monitoring`, `ingress-nginx`)
- **Labels**: lowercase with hyphens (e.g., `app.kubernetes.io/name`)
- ** helmRelease names**: Should match the release name (e.g., `external-dns` for chart `external-dns`)

### FluxCD Best Practices

1. **HelmRepository Placement**: Always in `flux-system` namespace
2. **HelmRelease Namespace**: Should match `targetNamespace`
3. **Dependencies**: Use `dependsOn` in HelmRelease for chart dependencies
4. **Wait for readiness**: Set `wait: true` in Kustomization for dependencies
5. **Health Checks**: Use `dependsOn` annotation for cross-namespace dependencies:
   ```yaml
   annotations:
     kustomize.toolkit.fluxcd.io/depends-on: helm.toolkit.fluxcd.io/HelmRelease/<namespace>/<name>
   ```

### Secrets

- **Pattern**: Files ending in `.secret.yaml` are encrypted with SOPS
- **Never commit plaintext secrets**
- Use `stringData` for SOPS-encrypted secrets
- Secrets must be in the same namespace as the consuming resource

### Kustomization Structure

Each directory must have a `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - resource1.yaml
  - resource2.yaml
```

### HelmRelease Values

- Use explicit versions (no `latest` or `*`)
- Set resource requests and limits
- Use `priorityClassName: "homelab-infrastructure"` for infrastructure components

### Observability

- Every service should export metrics
- Use `ServiceMonitor` from `monitoring.coreos.com/v1`
- Label with `release: victoriametrics`

## Common Issues & Solutions

### Issue: "no matches for kind"
**Cause**: CRD not installed (e.g., cert-manager not ready)
**Solution**: Add dependency annotation or ensure proper reconciliation order

### Issue: "timeout waiting for"
**Cause**: Resource taking too long or blocked by finalizers
**Solution**: Check resource status, delete stuck finalizers manually

### Issue: SOPS decryption failing
**Cause**: Secret not in expected format or wrong age key
**Solution**: Verify `.sops.yaml` rules match file pattern

## Renovation Configuration

See `renovate.json` for automated update rules. Key points:
- Flux HelmReleases: 7-day stability delay
- App container images: 3-day stability delay
- Automerge disabled for manual review

## Important Notes

1. **Always commit changes** before expecting Flux to reconcile
2. **Test locally** with `flux build kustomization` before pushing
3. **Check logs** with `kubectl logs -n flux-system` when debugging
4. **Respect dependency order**: base → sources → storage → network → observability → apps
