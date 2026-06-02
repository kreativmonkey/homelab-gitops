# Nextcloud CronJob failed (KubeJobFailed)

## Symptom

`KubeJobFailed` for namespace `nextcloud`, often **five** alerts at once.

## Why five alerts?

The Nextcloud Helm chart sets `cronjob.cronjob.failedJobsHistoryLimit: 5` by default. Each failed CronJob run leaves a Job object; Prometheus fires one alert per failed Job (`kube_job_failed > 0`).

Homelab sets `failedJobsHistoryLimit: 1` in `apps/base/nextcloud/helmrelease.yaml`.

## Quick checks

```bash
kubectl get cronjob,jobs -n nextcloud
kubectl get jobs -n nextcloud --field-selector status.successful!=1
kubectl logs -n nextcloud job/$(kubectl get jobs -n nextcloud -o name | tail -1 | cut -d/ -f2)
kubectl describe job -n nextcloud <job-name>
```

CronJob name is usually `nextcloud-cron` (release name + `-cron`).

## Common causes

| Cause | Fix |
|-------|-----|
| Stale **chart** `KubeJobFailed` VMRule (not real jobs) | `./scripts/monitoring/purge-chart-vmrules.sh monitoring` — see [monitoring-stack.md](monitoring-stack.md) |
| Wrong image tag (`33.0.3` without `-apache`) | Use `image.tag: 33.0.3-apache` in HelmRelease |
| Cron OOM / timeout on large NFS tree | Raise `cronjob.cronjob.resources.limits.memory`; `php -d memory_limit=512M` in command |
| Stale `.cron.lock` on NFS after killed pod | `kubectl exec -n nextcloud deploy/nextcloud -- rm -f /var/www/html/data/.cron.lock` (if present) |
| `maintenance:mode` still on | `kubectl exec -n nextcloud deploy/nextcloud -- php occ maintenance:mode --off` |
| Postgres/Redis unreachable from cron pod | Check CNPG + `nextcloud-redis-master`; same env as app via chart `nextcloud.env` |

## Clear alerts after fix

Failed Job objects must be deleted (or succeed on next run) for `kube_job_failed` to clear:

```bash
kubectl delete jobs -n nextcloud -l app.kubernetes.io/component=cronjob
flux reconcile helmrelease nextcloud -n nextcloud
```

## Verify

```bash
kubectl create job -n nextcloud nextcloud-cron-manual --from=cronjob/nextcloud-cron
kubectl logs -n nextcloud job/nextcloud-cron-manual -f
kubectl wait -n nextcloud --for=condition=complete job/nextcloud-cron-manual --timeout=600s
```

Expected: Job completes, log shows cron tasks without fatal errors.
