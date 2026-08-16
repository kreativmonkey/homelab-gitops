# Nextcloud Init:CrashLoopBackOff (occ-db-sync)

## Symptom

- `https://nc.f4mily.net` returns 502 / blackbox `EndpointDown`
- Pod `nextcloud-*` stuck in `Init:CrashLoopBackOff`
- Init container `occ-db-sync` fails; main container never starts
- CronJobs may still complete (misleading)

## Do not

- **Pod restart / rollout-restart** — with `strategy: Recreate` this causes downtime and does not fix Init-script errors
- n8n auto-remediation should block restarts when `failed_init_containers` is set (remediation-api `/v1/investigate`)

## Quick checks

```bash
kubectl get pods -n nextcloud -l app.kubernetes.io/name=nextcloud
kubectl logs -n nextcloud deploy/nextcloud -c occ-db-sync --tail=50
kubectl get helmrelease -n nextcloud nextcloud
```

## Common causes

| Cause | Fix |
|-------|-----|
| `occ-db-sync` rewrites `config.php` on every start and fails | GitOps: fast-path in `helmrelease.yaml` (skip rewrite when `occ status` OK) |
| Wrong DB password in `config.php` vs secret | Restore from secret; avoid `occ config:system:set dbpassword` without env |
| iSCSI / config read-only | Treat as filesystem incident; do not test writes or run `fsck` while mounted |
| Flux Ready but pod crash looping | `disableWait: true` on HelmRelease — check pod, not only HelmRelease status |

## iSCSI filesystem is read-only

`Read-only file system` or alert `IScsiEmergencyReadOnly` means kernel protected
filesystem after an error. Record pod, node, PVC/PV, device, CSI `globalmount`,
and recent node/CSI events first. Then stop every workload using volume before
unmounting or running filesystem repair. Never run `fsck` on mounted filesystem.

Detailed device mapping and offline-repair background:
[Nextcloud iSCSI Volume: Emergency Read-Only Remount](../learnings/nextcloud-iscsi-emergency-readonly.md).

## Manual recovery (DB password in config.php)

If `config.php` has wrong `dbpassword` and `occ` cannot boot:

```bash
kubectl scale deploy/nextcloud -n nextcloud --replicas=0
# Edit config.php on PVC subPath config (python/sed) using password from homelab-postgres-nextcloud secret
kubectl scale deploy/nextcloud -n nextcloud --replicas=1
```

## Verify

```bash
curl -sS -H 'Host: nc.f4mily.net' https://nc.f4mily.net/status.php
kubectl wait -n nextcloud --for=condition=ready pod -l app.kubernetes.io/component=app --timeout=300s
```
