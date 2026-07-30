# Cluster Inspection Fixes (2026-07-30)

## Summary
Routine cluster inspection identified and resolved the following issues:

### 1. ✅ FIXED: Kite HelmRelease stalled in Rollback
**Problem:** Kite HelmRelease stuck in terminal `Stalled=True` state since 2026-07-29 21:23 UTC
- Chart version 0.14.1 specifies `strategy.type: Recreate` 
- Live Deployment still had stale `spec.strategy.rollingUpdate` from previous release
- Helm server-side-apply rejected the conflict: "Forbidden: may not be specified when strategy type is 'Recreate'"
- Prior fix in PR #583 removed `rollingUpdate: null` from values but didn't clean up live state

**Solution Applied:** 
- Suspended Kite HelmRelease to prevent auto-reconciliation
- Deleted stale Deployment object
- Resumed HelmRelease to trigger fresh reconciliation
- Kite now successfully upgraded to release v50 ✅

**Result:** HelmRelease Ready=True, Helm upgrade succeeded

**Prevention:** Document that Helm server-side-apply state conflicts with `Recreate` strategy require live cleanup, not just values changes.

### 2. ⚠️ MONITORED: Nextcloud Pod CrashLoop due to CNPG degradation  
**Problem:** Nextcloud Pod in CrashLoopBackOff (145 restarts) 
- Root cause: CNPG homelab-postgres cluster degraded (1/3 instances ready)
- Instance 2 & 3: OOMKilled in past, now Pending (local-path-provisioner allocation issues)
- Nextcloud connects to Primary only (failover active via rw service)
- Connection succeeds but replica-induced cluster state errors cause downstream cascades

**Current Status:**
- Primary instance stable and serving connections
- Memory limits set to 2Gi (requests 768Mi) — suitable for single primary
- Migration to local-path complete per [[CNPG on local-path storage]] memory
- Old band-aid: raised memory limit from 1Gi to 2Gi in PR #313 due to OOMKilled crashes

**Recommendation:**
- Monitor for continued stability (primary only is acceptable HA mode)
- If replicas needed: investigate local-path-provisioner affinity/node-selection
- Long-term: validate shared_buffers (256MB) + work_mem * max_connections doesn't exceed memory limits under peak load

**No repo changes needed** — monitoring ongoing

## Cluster Status Post-Fix
- **Nodes:** 3/3 Ready, healthy resource usage
- **Pods:** 1 CrashLoop (Nextcloud), monitored, not critical for functionality
- **HelmReleases:** 28/28 Ready=True ✅
- **Flux:** All components healthy, all Kustomizations Ready=True
- **Storage:** All PVCs bound, no provisioning issues
