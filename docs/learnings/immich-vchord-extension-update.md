# Immich: vchord Extension Update Crashes Server on Startup

**Date**: 2026-06-08
**Severity**: critical
**Affected**: apps/base/immich
**Status**: workaround

## What Went Wrong

Immich v2.7.5 introduced automatic detection and update of the `vchord` vector extension on startup. The `immich` database user lacks PostgreSQL superuser privileges, so `ALTER EXTENSION vchord UPDATE TO '1.1.1'` fails with `permission denied`. This error is thrown as an uncaught exception, killing the API worker process → startup probe fails (port 2283 unreachable) → Kubernetes restarts the pod → CrashLoopBackOff.

## Why It Failed

1. **Immich assumes superuser** for extension management: The new code path at `DatabaseService` runs `ALTER EXTENSION vchord UPDATE` before the server finishes booting. No graceful fallback if the user lacks permissions.
2. **CNPG managed roles are not superusers**: The `immich` role is created via `spec.managed.roles` in the CNPG Cluster CR. These roles get `LOGIN` but not `SUPERUSER`, which is required for `ALTER EXTENSION ... UPDATE`.
3. **Uncaught exception design**: The PostgresError from the failed `ALTER EXTENSION` propagates as an unhandled promise rejection → `triggerUncaughtException` → process exit with code 1. No retry, no skip, no graceful degradation.

## The Correct Approach

### Immediate Fix

Connect to the Immich CNPG cluster and run the update as superuser:

```bash
kubectl exec -n cnpg-system immich-postgres-1 -- psql -U postgres -d immich -c "ALTER EXTENSION vchord UPDATE TO '1.1.1'"
```

Then force the server pod to restart (it will be in backoff):

```bash
kubectl delete pod -n immich -l app.kubernetes.io/name=server
```

### Verification

Check pod becomes Ready and logs show no vchord error:

```bash
kubectl get pods -n immich -l app.kubernetes.io/name=server
kubectl logs -n immich -l app.kubernetes.io/name=server --tail=20 | grep -i vchord
```

## Prevention

**TODO**: This will happen again with every Immich update that bumps the `vchord` extension. Need a sustainable solution:

- Option A: Grant `SUPERUSER` to the `immich` managed role in the CNPG Cluster CR — insecure but simple.
- Option B: Run extension updates as a pre-start init container / job using the `postgres` superuser credentials.
- Option C: Pin `vchord` extension version in the cluster image to match Immich's expectation, avoiding the update attempt.
- Option D: Monitor Immich releases for when they fix the upstream issue (graceful handling of non-superuser).

**Decision pending** — revisit before next Immich version bump.

## Related

- CNPG Cluster: `infrastructure/overlays/main/database-clusters/immich-postgres/cluster.yaml`
- HelmRelease: `apps/base/immich/helmrelease.yaml`
- Upstream issue: Immich auto-detects `vchord` and tries to update; no config flag to disable this behavior as of v2.7.5
- Base image: `ghcr.io/tensorchord/cloudnative-vectorchord:16.13`
