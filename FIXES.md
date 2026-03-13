# FluxCD Fixes - 2026-03-13

## Problem
FluxCD Kustomizations waren blockiert durch fehlende Pod Security Labels auf Namespaces und fehlende kustomization.yaml Dateien.

## Root Cause
**Pod Security Standards (PSS)** in Kubernetes 1.25+ blockieren privilegierte Pods (hostNetwork, hostPorts) standardmäßig. Ingress-nginx und Longhorn benötigen diese Rechte.

## Lösung

### 1. Pod Security Labels hinzugefügt
Namespaces `ingress-nginx` und `longhorn-system` benötigen `privileged` PSS-Level:

```yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
```

**Warum privileged?**
- **ingress-nginx**: Benötigt `hostNetwork: true` + `hostPort` (80, 443, 8443) um Traffic direkt auf Nodes zu empfangen
- **longhorn**: Benötigt Host-Zugriff für iSCSI und Storage-Management

### 2. Fehlende kustomization.yaml erstellt
- `infrastructure/controllers/kustomization.yaml`
- `infrastructure/config/kustomization.yaml`
- `apps/kustomization.yaml`

### 3. Homer Dashboard installiert
Simple Dashboard-Lösung ohne Datenbank, konfiguriert via ConfigMap.

## Status

✅ **Funktionierende Services:**
- cert-manager (inkl. Hetzner DNS webhook)
- ingress-nginx (3 Pods auf Control Planes)
- Homer Dashboard

⚠️ **Longhorn Status:**
- Deployment fehlgeschlagen (longhorn-manager CrashLoopBackOff)
- **Grund**: Talos Linux benötigt spezielle Konfiguration für iSCSI/Storage
- **Fix notwendig**: Talos Machine Config muss iscsid + Kernel-Module aktivieren
- **Dokumentation**: https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/

## Zugriff

### Homer Dashboard
- **URL**: http://homer.homelab.local
- **Ingress**: nginx (mit Let's Encrypt TLS)
- **Config**: ConfigMap `homer-config` in Namespace `homer`

Um die Config zu ändern:
```bash
kubectl edit configmap homer-config -n homer
kubectl rollout restart deployment homer -n homer
```

### DNS
Stelle sicher dass `homer.homelab.local` auf die Control Plane IPs zeigt:
- 192.168.10.245 (oder Load Balancer vor den Control Planes)

## Nächste Schritte

### Longhorn reparieren:
1. Talos Machine Config erweitern (iscsid enablen)
2. `talosctl apply-config` auf allen Nodes
3. HelmRelease neu starten

### Git Push Problem:
- GitHub PAT in `~/.git-credentials` ist expired/ungültig
- Neuen PAT erstellen mit `repo` scope
- Dann: `git push` um alle lokalen Änderungen zu synchronisieren

## Best Practices

1. **Pod Security Standards beachten**: Nicht jeder Namespace braucht `privileged`
2. **Namespace-spezifische Labels**: Pro Use-Case das minimal notwendige Level
3. **GitOps**: Alle Änderungen sollten via Git laufen (nicht kubectl apply)
4. **Talos**: Spezielle OS-Anforderungen für Storage/Networking vorher prüfen

## Flux Dependency Chain

```
flux-system (OK)
    ↓
infrastructure-controllers (OK außer longhorn)
    ↓
infrastructure-config (wartet)
    ↓
apps (wartet)
```

Sobald longhorn gefixt ist, wird die gesamte Chain durchlaufen.
