# NGINX Ingress Migration - Pre-Migration Validation Checklist

**Use this checklist to verify all prerequisites are addressed before executing the migration plan.**

---

## Phase 0: Pre-Flight Checks

- [ ] **Read and understand the migration plan** (`.opencode/plans/nginx-ingress-migration-plan.md`)
- [ ] **Read and understand this audit report** (`.opencode/audit/nginx-ingress-migration-security-audit.md`)
- [ ] **Schedule maintenance window** (5-9 days estimated)
- [ ] **Notify users** of ingress-based services about potential downtime

---

## Phase 1: Create Required Resources

### 1.1 Add ServiceMonitor (CRITICAL)

- [ ] Create file: `infrastructure/network/ingress/servicemonitor.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nginx-ingress
  namespace: ingress-nginx
  labels:
    release: victoriametrics
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: nginx-ingress
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
```

- [ ] Update: `infrastructure/network/ingress/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
  - servicemonitor.yaml  # ADD THIS LINE
```

- [ ] Verify kustomize build: `flux build kustomization infra-base --path infrastructure/base`

### 1.2 Create Backup Directory

- [ ] Create directory: `.opencode/backups/`
  ```bash
  mkdir -p .opencode/backups
  ```

### 1.3 Generate Backups

- [ ] Backup current HelmRelease:
  ```bash
  kubectl get hr ingress-nginx -n ingress-nginx -o yaml > \
    .opencode/backups/ingress-nginx-backup-$(date +%Y%m%d-%H%M%S).yaml
  ```

- [ ] Backup current IngressClass:
  ```bash
  kubectl get ingressclass nginx -o yaml > \
    .opencode/backups/ingressclass-backup-$(date +%Y%m%d-%H%M%S).yaml
  ```

- [ ] Backup all Ingress resources:
  ```bash
  kubectl get ingress -A -o yaml > \
    .opencode/backups/ingress-all-backup-$(date +%Y%m%d-%H%M%S).yaml
  ```

- [ ] Commit backups to Git:
  ```bash
  git add .opencode/backups/
  git commit -m "Backup: Pre-migration snapshots for ingress-nginx"
  git push
  ```

---

## Phase 2: Verify External Dependencies

### 2.1 OCI Registry Accessibility

- [ ] Verify chart is accessible:
  ```bash
  helm repo add nginx-charts oci://ghcr.io/nginx/charts
  helm search repo nginx-charts/nginx-ingress --version 2.5.0
  ```

- [ ] Pull chart metadata:
  ```bash
  helm pull oci://ghcr.io/nginx/charts/nginx-ingress --version 2.5.0 --untar --untardir /tmp
  ```

- [ ] Inspect chart values:
  ```bash
  helm show values oci://ghcr.io/nginx/charts/nginx-ingress --version 2.5.0 | head -50
  ```

- [ ] ✅ Document any unusual values or required overrides

### 2.2 Security Context Verification

- [ ] Examine default security context:
  ```bash
  helm show values oci://ghcr.io/nginx/charts/nginx-ingress --version 2.5.0 | \
    grep -A 30 "securityContext\|capabilities\|runAsUser"
  ```

- [ ] Verify it includes:
  - [ ] `runAsNonRoot: false` (or similar for root requirement)
  - [ ] `capabilities` or reference to CAP_NET_BIND_SERVICE
  - [ ] No unexpected escalations

- [ ] ✅ Document findings in a separate security verification file

### 2.3 FluxCD Configuration

- [ ] Verify OCI source type is supported:
  ```bash
  flux get sources helm --all-namespaces
  flux version
  ```

- [ ] ✅ Ensure FluxCD version supports `type: "oci"` HelmRepository

---

## Phase 3: Validate Current State

### 3.1 Check Current Ingress-NGINX Status

- [ ] Verify community ingress-nginx is running:
  ```bash
  kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx
  ```

- [ ] Check HelmRelease status:
  ```bash
  kubectl describe hr ingress-nginx -n ingress-nginx
  ```

- [ ] Verify controller version:
  ```bash
  kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=20 | grep version
  ```

### 3.2 Validate Ingress Resources

- [ ] List all Ingress resources:
  ```bash
  kubectl get ingress -A
  ```

- [ ] ✅ Verify count matches plan (should have 8 Ingress objects)

- [ ] Test connectivity to each service:
  ```bash
  # Example - replace with actual domains
  curl -v https://homer.f4mily.net/
  curl -v https://home.cluster.f4mily.net/
  curl -v https://metrics.cluster.f4mily.net/
  curl -v https://grafana.cluster.f4mily.net/
  curl -v https://longhorn.cluster.f4mily.net/
  ```

### 3.3 Verify Metrics Collection

- [ ] Check Prometheus scrape targets:
  ```bash
  kubectl port-forward -n monitoring svc/vmsingle-vm-k8s-stack 8428:8428 &
  curl -s 'http://localhost:8428/api/v1/targets' | jq '.activeTargets | length'
  ```

- [ ] ✅ Note baseline metrics count for comparison after migration

---

## Phase 4: Deploy Infrastructure Changes

### 4.1 Add OCI Repository

- [ ] Edit: `infrastructure/sources/helm-repositories.yaml`
- [ ] Add entry:
  ```yaml
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

- [ ] Verify syntax: `flux build kustomization infra-sources --path infrastructure/sources`

- [ ] Commit:
  ```bash
  git add infrastructure/sources/helm-repositories.yaml
  git commit -m "Add F5 NGINX Ingress OCI repository"
  git push
  ```

- [ ] ✅ Monitor Flux reconciliation:
  ```bash
  flux get sources helm -n flux-system -w
  ```

### 4.2 Update IngressClass

- [ ] Edit: `infrastructure/sources/ingressclass.yaml`
- [ ] Change controller:
  ```yaml
  spec:
    controller: nginx.org/ingress-controller  # Changed from k8s.io/ingress-nginx
  ```

- [ ] Commit:
  ```bash
  git add infrastructure/sources/ingressclass.yaml
  git commit -m "Update IngressClass controller to nginx.org"
  git push
  ```

- [ ] ⚠️ **WARNING:** Both controllers will coexist temporarily. Ingress resources may become unreachable until migration completes.

- [ ] Verify update:
  ```bash
  kubectl get ingressclass nginx -o yaml | grep controller
  ```

### 4.3 Deploy F5 NGINX Ingress Controller (Blue-Green)

- [ ] Edit: `infrastructure/network/ingress/helmrelease.yaml`
- [ ] Update HelmRelease (keep community version temporarily):
  ```yaml
  apiVersion: helm.toolkit.fluxcd.io/v2
  kind: HelmRelease
  metadata:
    name: nginx-ingress  # Change from ingress-nginx
    namespace: ingress-nginx
  spec:
    chart:
      spec:
        chart: nginx-ingress
        version: "2.5.0"
        sourceRef:
          kind: HelmRepository
          name: nginx-ingress-repo  # New repo
          namespace: flux-system
    values:
      controller:
        kind: DaemonSet
        hostNetwork: true
        dnsPolicy: ClusterFirstWithHostNet
        priorityClassName: "homelab-infrastructure"
        # ... rest from plan
  ```

- [ ] Commit:
  ```bash
  git add infrastructure/network/ingress/helmrelease.yaml
  git commit -m "Deploy F5 NGINX Ingress Controller v2.5.0 (blue-green)"
  git push
  ```

- [ ] Monitor deployment:
  ```bash
  kubectl get hr -n ingress-nginx -w
  kubectl get pods -n ingress-nginx -w
  ```

- [ ] ✅ Verify both controllers are running:
  ```bash
  kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx
  kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=nginx-ingress
  ```

### 4.4 Add ServiceMonitor

- [ ] ✅ ServiceMonitor should be included in previous commit

- [ ] Verify ServiceMonitor is active:
  ```bash
  kubectl get servicemonitor -n ingress-nginx
  kubectl describe servicemonitor nginx-ingress -n ingress-nginx
  ```

---

## Phase 5: Migrate Application Ingress Annotations

**Perform one at a time, verifying each before proceeding.**

### 5.1 Migrate Homer

- [ ] Edit: `apps/homer/ingress.yaml`
- [ ] Change annotation:
  ```yaml
  nginx.org/ssl-redirect: "true"  # from nginx.ingress.kubernetes.io/ssl-redirect
  ```

- [ ] Test: `curl -v https://homer.f4mily.net/`

- [ ] ✅ Confirm accessibility before proceeding

### 5.2 Migrate Homepage

- [ ] Edit: `apps/homepage/ingress.yaml`
- [ ] Change annotation
- [ ] Test: `curl -v https://home.cluster.f4mily.net/`

### 5.3 Migrate Victoria Metrics Ingress

- [ ] Edit: `apps/monitoring/vm-k8s-stack/ingress-victoria-metrics.yaml`
- [ ] Change annotation
- [ ] Test: `curl -v https://metrics.cluster.f4mily.net/`

### 5.4 Migrate Grafana Ingress

- [ ] Edit: `apps/monitoring/vm-k8s-stack/ingress-grafana.yaml`
- [ ] Change annotation
- [ ] Test: `curl -v https://grafana.cluster.f4mily.net/`

### 5.5 Migrate Storage (Longhorn)

- [ ] Edit: `infrastructure/storage/ingress.yaml`
- [ ] Change annotations:
  ```yaml
  nginx.org/ssl-redirect: "true"
  nginx.org/client-max-body-size: "1000m"  # from proxy-body-size
  ```

- [ ] Test: `curl -v https://longhorn.cluster.f4mily.net/`

### 5.6 Migrate Audiobookshelf

- [ ] Edit: `apps/audiobookshelf/deployment.yaml` (lines 82-107)
- [ ] Change annotations
- [ ] Test file upload functionality
- [ ] Test: `curl -v https://audible.media.f4mily.net/`

### 5.7 Migrate Kite

- [ ] Edit: `apps/kite/deployment.yaml` (lines 65-80)
- [ ] Change annotation in HelmRelease values
- [ ] Test: `curl -v https://kite.f4mily.net/`

### 5.8 Migrate Sterling-PDF

- [ ] Edit: `apps/sterling-pdf/deployment.yaml` (lines 93-107)
- [ ] Change annotation in HelmRelease values
- [ ] Test file upload functionality
- [ ] Test: `curl -v https://sterling-pdf.f4mily.net/`

### 5.9 Commit All Changes

```bash
git add apps/ infrastructure/
git commit -m "Migrate ingress annotations to F5 NGINX Ingress Controller"
git push
```

---

## Phase 6: Cleanup and Verification

### 6.1 Remove Community Ingress-NGINX

- [ ] Verify all annotations have been migrated (Phase 5 complete)

- [ ] Delete old HelmRelease:
  ```bash
  kubectl delete hr ingress-nginx -n ingress-nginx
  # OR manually remove from infrastructure/network/ingress/helmrelease.yaml
  ```

- [ ] Monitor cleanup:
  ```bash
  kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -w
  ```

- [ ] ✅ Verify old pods are terminating

### 6.2 Verify Metrics Collection

- [ ] Check ServiceMonitor targets:
  ```bash
  kubectl describe servicemonitor nginx-ingress -n ingress-nginx
  ```

- [ ] Verify VictoriaMetrics is scraping:
  ```bash
  kubectl exec -n monitoring vmsingle-vm-k8s-stack-0 -- \
    curl -s "http://localhost:8428/api/v1/targets" | \
    jq '.activeTargets[] | select(.labels.job=="nginx-ingress")'
  ```

- [ ] ✅ Compare metrics count with baseline from Phase 3

### 6.3 Validate All Services

- [ ] Test all Ingress endpoints again:
  ```bash
  curl -v https://homer.f4mily.net/
  curl -v https://home.cluster.f4mily.net/
  curl -v https://metrics.cluster.f4mily.net/
  curl -v https://grafana.cluster.f4mily.net/
  curl -v https://longhorn.cluster.f4mily.net/
  curl -v https://audible.media.f4mily.net/
  curl -v https://kite.f4mily.net/
  curl -v https://sterling-pdf.f4mily.net/
  ```

- [ ] ✅ All services returning 200/30x responses

### 6.4 Check Logs for Errors

- [ ] Review F5 NIC logs:
  ```bash
  kubectl logs -n ingress-nginx -l app.kubernetes.io/name=nginx-ingress --tail=50 | grep -i error
  ```

- [ ] Review controller status:
  ```bash
  kubectl get hr -n ingress-nginx -o wide
  ```

- [ ] ✅ No error conditions

### 6.5 Final Cleanup

- [ ] Remove old HelmRepository reference (optional):
  ```bash
  # Edit infrastructure/sources/helm-repositories.yaml
  # Remove: ingress-nginx-repo pointing to kubernetes.github.io
  ```

- [ ] Archive backups:
  ```bash
  git add .opencode/backups/
  git commit -m "Archive pre-migration backups"
  git push
  ```

- [ ] ✅ Final git log shows successful migration commits

---

## Rollback Procedure (If Needed)

If issues occur during migration:

1. [ ] **Identify the problem**
   ```bash
   kubectl logs -n ingress-nginx -l app.kubernetes.io/name=nginx-ingress
   kubectl describe hr nginx-ingress -n ingress-nginx
   ```

2. [ ] **Restore from git backup**
   ```bash
   git checkout HEAD~N -- infrastructure/ apps/  # N = number of commits back
   git commit -m "Rollback: Revert to community ingress-nginx"
   git push
   ```

3. [ ] **Flux will auto-reconcile**
   ```bash
   flux reconcile kustomization infra-sources --with-source
   flux reconcile kustomization infra-base --with-source
   ```

4. [ ] **Verify old controller is back**
   ```bash
   kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx
   ```

5. [ ] **Restore services**
   ```bash
   # All annotations will revert to community format
   curl -v https://homer.f4mily.net/
   ```

---

## Sign-Off

**Migration Completion Checklist:**

- [ ] All prerequisites addressed (Phase 1)
- [ ] External dependencies verified (Phase 2)
- [ ] Current state validated (Phase 3)
- [ ] Infrastructure changes deployed (Phase 4)
- [ ] All annotations migrated (Phase 5)
- [ ] Cleanup complete (Phase 6)
- [ ] All services verified working
- [ ] Metrics collection confirmed
- [ ] No errors in logs
- [ ] Rollback procedure tested (recommended)

**Sign-Off:**

```
Migrated By:  ___________________
Date:         ___________________
Verified By:  ___________________
Date:         ___________________
```

---

**For questions or issues, refer to:**
- Full audit report: `.opencode/audit/nginx-ingress-migration-security-audit.md`
- Migration plan: `.opencode/plans/nginx-ingress-migration-plan.md`
- AGENTS.md: Coding and security guidelines

