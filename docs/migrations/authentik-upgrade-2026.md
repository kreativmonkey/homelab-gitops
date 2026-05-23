# Authentik Upgrade: 2025.12.4 → 2026.x

Production DB was migrated from Docker at **2025.12.4**. Upgrades must follow Authentik’s
[supported sequence](https://docs.goauthentik.io/install-config/upgrade/) — **no skipping major.minor
releases** (e.g. do not jump 2025.12 → 2026.5 without passing 2026.2).

## Target version

| Step | Chart / image | Notes |
|------|---------------|-------|
| Current | `2026.2.3` | Stable after 2025.12 → 2026.2 upgrade |
| Next | `2026.5.x` (latest patch) | Required next major; read [2026.5 release notes](https://docs.goauthentik.io/releases/2026.5/) |

## Pre-flight checklist

1. **Maintenance window** — login flows offline for several minutes during migrations.
2. **CNPG backup** — on-demand before upgrade:
   ```bash
   kubectl apply -f - <<EOF
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata:
     name: authentik-pre-upgrade-$(date +%Y%m%d)
     namespace: cnpg-system
   spec:
     cluster:
       name: homelab-postgres
     method: barmanObjectStore
   EOF
   kubectl wait -n cnpg-system --for=jsonpath='{.status.phase}'=completed \
     backup/authentik-pre-upgrade-$(date +%Y%m%d) --timeout=600s
   ```
   Optional logical dump (authentik DB only, restore via NodePort 30433):
   ```bash
   pg_dump -h 192.168.10.41 -p 30433 -U authentik -d authentik -Fc --no-owner --no-acl \
     -f Migration/authentik/backups/authentik-pre-upgrade.dump
   ```
   Requires PostgreSQL **18** client (`nix shell nixpkgs#postgresql_18`).
3. **Secret key** — `authentik-secret-key` SOPS must hold the production ASCII key (same as Docker).
4. **Disk headroom** — Talos root ~20 GiB; ensure nodes are not in `DiskPressure` (see runbook below).
5. **HelmRelease** — `server.deploymentStrategy: Recreate` (RWO media PVC).
6. **Outposts** — embedded proxy outposts upgrade with server/worker (same image tag).

## Breaking changes (2025.12 → 2026.2)

- **File storage path**: local files move from `/media` → `/data/media` (mount parent `/data`).
  Update Helm values before upgrading to 2026.2 (see Phase 2).
- **Outpost version skew**: server and outposts must run the same version.
- **RBAC migrations**: if a prior failed upgrade left the DB half-migrated, restore from backup
  before retrying ([issue #20734](https://github.com/goauthentik/authentik/issues/20734)).

## Phase 1 — GitOps prep (no cluster change)

1. Update `apps/base/authentik/helmrelease.yaml`:
   - `version: "2026.2.x"` (latest patch from `helm search repo authentik --versions`).
   - Add volume mount changes for `/data` (example):

   ```yaml
   server:
     deploymentStrategy:
       type: Recreate
     volumes:
       - name: data
         persistentVolumeClaim:
           claimName: authentik-media   # reuse PVC; mount as /data
     volumeMounts:
       - name: data
         mountPath: /data
   ```

   Move existing PVC content once: `media/*` → `data/media/` (Job or `kubectl cp`).

2. Remove Renovate pin `allowedVersions: "<2026"` in `renovate.json` after successful upgrade.

3. PR + CI (`just validate-full`).

## Phase 2 — Staged upgrade (cluster)

```bash
export KUBECONFIG=homelab-infrastructure/talos/kubeconfig

# 1. Suspend auto-reconcile during manual steps
flux suspend helmrelease authentik -n authentik

# 2. Scale down
kubectl scale deploy -n authentik authentik-server authentik-worker --replicas=0

# 3. Migrate media PVC layout (2026.2 requires /data/media)
kubectl apply -f apps/base/authentik/media-migrate-job.yaml
kubectl wait -n authentik --for=condition=complete job/authentik-media-migrate --timeout=300s
kubectl delete job -n authentik authentik-media-migrate --ignore-not-found

# 4. Merge GitOps PR → flux reconcile OR helm upgrade --version 2026.2.x

# 5. Watch migrations
kubectl logs -n authentik -l app.kubernetes.io/component=server -c server -f

# 6. Verify
curl -skI --resolve login.f4mily.net:443:192.168.10.245 https://login.f4mily.net/
# Admin → Outposts → health green; test Grafana/Forgejo OAuth

flux resume helmrelease authentik -n authentik
```

## Phase 3 — Post-upgrade

- Bump to latest **2026.2.x** patch via Renovate.
- Only after 2026.2 stable: plan **2026.4** / **2026.5** as separate maintenance (same sequence rules).
- Update `docs/migrations/authentik-docker-to-kubernetes.md` target version table.

## Rollback

Authentik **does not support downgrades**. On migration failure:

1. Scale deployments to 0.
2. Restore CNPG DB from backup taken in pre-flight.
3. Re-deploy chart `2025.12.4`.
4. Investigate logs for `migration inconsistency` before retry.

## Estimated effort

| Scenario | Effort |
|----------|--------|
| Clean 2025.12.4 DB, no failed 2026 attempts | ~1–2 h (GitOps + PVC path + verify OAuth) |
| Prior failed 2026.x upgrade on this DB | Half day+ (restore + possible manual SQL per upstream issues) |
| Skip sequence (2025.12 → 2026.5 direct) | **Not supported** — high risk of broken RBAC schema |
