# Kite HelmRelease: Helm Strategy Type Conflict Fix

## Problem
Kite HelmRelease enters terminal `Stalled=True` state with error:
```
Helm upgrade failed ... Deployment.apps "kite-kite" is invalid: 
spec.strategy.rollingUpdate: Forbidden: may not be specified when 
strategy type is 'Recreate'
```

## Root Cause
When the Kite chart version changes from `strategy.type: RollingUpdate` to `strategy.type: Recreate`:
1. New chart values set `deploymentStrategy: {type: Recreate}` (no `rollingUpdate`)
2. Live Deployment still has stale `spec.strategy.rollingUpdate` from previous release
3. Helm server-side-apply rejects the conflict — can't have both `type: Recreate` AND `rollingUpdate` config

## Solution
**Option 1: Automatic (if you control the chart/values)**
- Ensure Kite HelmRelease values only specify `deploymentStrategy: {type: Recreate}`
- Do NOT add `rollingUpdate: null` — explicit null still renders in YAML and triggers the conflict
- Omit the key entirely

**Option 2: Manual Cluster Recovery (if live state is stuck)**
```bash
# 1. Suspend the HelmRelease to prevent auto-reconciliation
kubectl patch hr -n kite kite -p '{"spec":{"suspend":true}}' --type=merge

# 2. Delete the stale Deployment
kubectl delete deploy -n kite kite-kite

# 3. Resume to trigger fresh Helm apply
kubectl patch hr -n kite kite -p '{"spec":{"suspend":false}}' --type=merge

# 4. Verify upgrade succeeded
kubectl get hr -n kite kite -w
```

This forces Helm to re-render the Deployment from scratch without the stale `rollingUpdate` conflict.

## Prevention
- Helm server-side-apply state mutations (like stale fields in live objects) are NOT automatically fixed by changing values
- Always clean up live state before Helm retries
- Document any known chart/strategy conflicts as known issues until the upstream chart is fixed
