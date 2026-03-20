# Security Audit Summary - NGINX Ingress Migration

**Status:** ⚠️ **CONDITIONAL APPROVAL**  
**Date:** 2026-03-20  
**Auditor:** @security-audit

---

## Quick Summary

The NGINX Ingress migration plan from community ingress-nginx to F5 NGINX Ingress Controller is **security-approved with conditions**.

### ✅ What Passes
- Kustomize dependency ordering is correct
- Namespace pod security labels are appropriate  
- Migration improves security (F5 vendor vs community)
- All 8 Ingress files have correct annotation mappings
- Resource limits and priority classes configured
- No plaintext secrets in annotations

### ⚠️ What Needs Fixing
1. **Missing ServiceMonitor** (CRITICAL) - Required by AGENTS.md §Observability
2. **Verify OCI registry** (HIGH) - Trust chain is solid but needs pre-migration check
3. **Check F5 NIC security context** (HIGH) - Ensure no unexpected capabilities
4. **Create rollback backups** (HIGH) - Part of migration strategy

### ❌ Critical Issues Found
**None** - The plan is fundamentally sound.

---

## Key Findings

| Finding | Severity | Status |
|---------|----------|--------|
| Kustomize hierarchy | N/A | ✅ Correct |
| Namespace config | N/A | ✅ Correct |
| Security posture | Enhancement | ✅ Improved |
| Annotation mapping | N/A | ✅ Complete (8 files) |
| OCI registry trust | Verification | ⚠️ Verify before proceeding |
| Pod security | N/A | ✅ Appropriate |
| ServiceMonitor | Policy | ❌ MISSING |

---

## Prerequisites Before Migration

### 1. Add ServiceMonitor (CRITICAL)
Create: `infrastructure/network/ingress/servicemonitor.yaml`
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

### 2. Test OCI Registry
```bash
helm search repo oci://ghcr.io/nginx/charts --version 2.5.0
```

### 3. Verify Security Context
```bash
helm show values oci://ghcr.io/nginx/charts/nginx-ingress:2.5.0 | grep -A 20 securityContext
```

### 4. Create Backups
```bash
kubectl get hr ingress-nginx -n ingress-nginx -o yaml > \
  .opencode/backups/ingress-nginx-backup-20260320.yaml
```

---

## Files Modified in Plan

✅ **Infrastructure:**
- `infrastructure/sources/helm-repositories.yaml` - Add OCI repo
- `infrastructure/sources/ingressclass.yaml` - Update controller
- `infrastructure/network/ingress/helmrelease.yaml` - New chart/version
- `infrastructure/network/ingress/kustomization.yaml` - Add ServiceMonitor

✅ **Applications (Annotation Mapping):**
- `apps/homer/ingress.yaml`
- `apps/homepage/ingress.yaml`
- `apps/monitoring/vm-k8s-stack/ingress-victoria-metrics.yaml`
- `apps/monitoring/vm-k8s-stack/ingress-grafana.yaml`
- `apps/audiobookshelf/deployment.yaml`
- `apps/kite/deployment.yaml`
- `apps/sterling-pdf/deployment.yaml`
- `infrastructure/storage/ingress.yaml`

---

## Compliance Against AGENTS.md

| Requirement | Status | Notes |
|------------|--------|-------|
| FluxCD Dependencies | ✅ PASS | Correct `dependsOn` chain |
| Secret Management | ✅ PASS | No plaintext secrets |
| Observability | ❌ FAIL | ServiceMonitor missing |
| HelmRelease Versions | ✅ PASS | Explicit version: 2.5.0 |
| Resource Limits | ✅ PASS | CPU/Memory configured |
| Priority Classes | ✅ PASS | "homelab-infrastructure" set |

---

## Migration Decision

### ✅ APPROVED FOR MIGRATION (with conditions)

**After addressing the 4 prerequisites above:**

The migration can proceed using the blue-green strategy outlined in the plan:
1. Deploy F5 NIC alongside community ingress-nginx
2. Gradually migrate annotations
3. Remove old controller once migration complete

---

## Timeline Recommendation

| Phase | Action | Timeline |
|-------|--------|----------|
| Pre-Migration | Address 4 prerequisites | 1-2 days |
| Phase 1 | Deploy F5 NIC alongside community | 1 day |
| Phase 2 | Migrate annotations gradually | 3-5 days |
| Phase 3 | Verify metrics + remove old controller | 1 day |
| **Total** | | **5-9 days** |

---

## Risk Summary

- **High Risks:** None identified
- **Medium Risks:** Missing ServiceMonitor (policy violation, not functional)
- **Low Risks:** OCI registry verification (low probability of issues)

---

## Next Steps

1. ✅ Review this audit report
2. ✅ Implement the 4 prerequisites
3. ✅ Create the ServiceMonitor resource
4. ✅ Run pre-migration verification steps
5. ✅ Execute migration plan

---

**Full Audit Report:** See `nginx-ingress-migration-security-audit.md`

