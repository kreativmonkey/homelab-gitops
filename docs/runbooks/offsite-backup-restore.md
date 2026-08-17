# Immich and Nextcloud offsite backup

## Scope

Daily Restic snapshots are stored encrypted on the Hetzner Storage Box under
`homelab-gitops/restic`:

- `immich`: PostgreSQL dump plus complete `Bilder` and `Fotos` NFS trees.
- `nextcloud`: Garage primary-object bucket, PostgreSQL dump, and a tar archive
  of `/var/www/html` containing config, apps, themes, and compatibility data.

The Nextcloud job now holds Nextcloud in maintenance mode only for the
consistency-critical core: incremental object re-sync, `pg_dump`, and the
app-state tar. The object prefetch (several hours on the first run) and the
restic upload run with Nextcloud online. A native sidecar releases
maintenance mode on success, on failure, and on graceful pod termination,
and verifies the release against `occ config:system:get maintenance`. A hard
kill (node loss, SIGKILL) still bypasses that release — the job then fails
and `NextcloudMaintenanceModeStuck` covers it. The staging PVC is an on-site
working copy, not a backup.

Retention is 14 daily, 8 weekly, 12 monthly, and 3 yearly snapshots per app.
Weekly verification reads 5% of repository data, restores both database dumps
and Nextcloud app state, validates them with `pg_restore --list` and `tar`, then
restores one Immich media file and one Nextcloud object and checks both against
their backup-time SHA-256 hashes. Only then does it compact unreferenced data.

## Check status

```bash
kubectl get cronjob,jobs -n backup-offsite
kubectl logs -n backup-offsite job/<job-name> --all-containers
kubectl get pvc -n backup-offsite nextcloud-offsite-staging
```

Trigger an additional backup or verification:

```bash
kubectl create job -n backup-offsite --from=cronjob/immich-offsite-backup immich-offsite-manual
kubectl create job -n backup-offsite --from=cronjob/nextcloud-offsite-backup nextcloud-offsite-manual
kubectl create job -n backup-offsite --from=cronjob/offsite-restore-verify offsite-verify-manual
```

After the first seed, require all three jobs to complete before treating the
Storage Box as a valid offsite copy.

## Nextcloud job: flow and stuck maintenance mode

Container order in the Nextcloud backup job: `fetch-garage-credentials` →
`prepare-rclone` → `restic-server` (sidecar) → `stage-objects-prefetch`
(without maintenance mode) → `maintenance` (sidecar, turns it on) →
`wait-maintenance` → `stage-objects` (in maintenance mode, authoritative) →
`capture-state` → `backup` (restic, Nextcloud back online) → `finalize`.

Flag files in `/work` and what they mean:

- `maintenance-ready`
- `capture-complete` (releases maintenance mode, written on every path)
- `maintenance-off`
- `maintenance-off.failed`
- `nextcloud-stage.ok`
- `nextcloud-capture.ok`
- `nextcloud.ok`

`finalize` names any missing flags in the log.

Failure mode "Nextcloud stuck in maintenance mode": caused by a read-only
`/var/www/html/config` in the Nextcloud pod (iSCSI remount), which made
`occ maintenance:mode --off` fail. The job now retries the release until
verified success and otherwise leaves `/work/maintenance-off.failed`, which
fails the job. Manual release:

```bash
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- php occ maintenance:mode --off
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- php occ config:system:get maintenance
```

The blackbox probe for Nextcloud now targets `https://nc.f4mily.net/status.php`
instead of the root URL, because in maintenance mode the root URL responds
with 503 (verified) while `status.php` responds with 200 and `"maintenance":
true` in the body — so a regular, short maintenance window no longer trips
`EndpointDown`. Instead, a dedicated alert `NextcloudMaintenanceModeStuck`
(in `apps/base/monitoring/rules/blackbox-vmrule.yaml`) fires after 30 minutes
when `status.php` reports `maintenance=true` while Nextcloud is reachable.
It relies on a dedicated blackbox module `http_2xx_nextcloud_online`
(`fail_if_body_matches_regexp`) and a dedicated VMProbe
`blackbox-http-nextcloud-online`.

## Full restore test

Automated weekly verification proves repository readability and both database
dumps. It does not start production applications. Before trusting retention,
also perform this isolated restore:

1. Suspend the application HelmRelease or restore into an isolated test cluster.
2. Start from a copy of `offsite-restore-verify` with `restic restore latest`
   for the required `--tag` and without the dump-only `--include` filter.
3. Restore the PostgreSQL dump into a fresh CNPG cluster using `pg_restore`.
4. Immich: mount restored `Bilder` and `Fotos`, deploy the matching Immich
   version, then run its storage-integrity check.
5. Nextcloud: restore `nextcloud-app.tar.gz`, upload the staged `objects/`
   directory to an empty Garage bucket, restore its database, and keep the
   restored bucket exclusive to that instance.
6. Run `php occ maintenance:data-fingerprint`, `php occ status`, and download
   several known files through Nextcloud. Never run `files:scan --all` against
   primary object storage.

Record restore date, snapshot IDs, tested files, and result in the operations
log. A failed verification blocks pruning or storage migrations until fixed.

## Lost credentials

Storage Box login and Restic repository password live only in the SOPS Secret
`infrastructure/base/offsite-backup/storagebox-credentials.secret.yaml`.
Loss of the Restic password makes every snapshot unrecoverable; keep a second
copy in the offline password manager.
