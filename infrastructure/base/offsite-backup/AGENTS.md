# Purpose

Encrypted offsite backups of irreplaceable Immich, Nextcloud, and Forgejo data to the Hetzner Storage Box. This is the primary protection for volume data — Velero keeps Kubernetes objects, CNPG keeps databases locally for fast restores.

# Ownership

- Owns: Storage Box credentials, Restic repository jobs, Nextcloud backup staging, restore verification, and namespace-scoped backup RBAC.
- Parent `infrastructure/AGENTS.md` owns cluster-wide storage and backup policy.

# Local Contracts

- Storage Box credentials and Restic password stay SOPS-encrypted in `storagebox-credentials.secret.yaml`.
- Restic is the durable backup format; rclone only exposes the SFTP target and stages Nextcloud S3 objects.
- All jobs share one Restic repository, and `forget`/`prune`/`check` take an exclusive lock. Every locking command therefore passes `--retry-lock`, so an overlapping job queues instead of failing. Do not rely on schedule spacing alone — runtimes change.
- Immich backups include `Bilder`, `Fotos`, and a fresh PostgreSQL dump.
- The `databases` job dumps every database of every CNPG cluster. Clusters and databases are discovered from pod labels and `pg_database`, never listed in the manifest — a list would rot and silently leave new apps unprotected. Barman keeps the same data locally for fast restores; this job is the copy that survives losing the NAS. The per-app jobs keep their own dump so data and database restore as a matching pair.
- `storagebox-quota-check` fails once free space on the Storage Box drops below its threshold. The quota is shared with other backups on the same box, and a full box blocks writing clients entirely — including their lock files, which makes cleanup impossible from the inside.
- Paperless backups include the document archive and its search-index data, plus a fresh dump of the `paperless` database. `consume/` and `export/` stay out: they are transit directories.
- The `appdata` job covers application state that only costs manual work after a total loss (Jellyfin and Kavita library config, Tandoor static and media files). Their databases come from the `databases` job.
- Volumes on RWO iSCSI cannot be mounted by a second pod. Backing them up means `kubectl exec` into the owning pod, which buys the backup ServiceAccount exec rights in that namespace — only worth it when the volume holds state that is not in a database. That is why `authentik-media` is not backed up: re-uploadable assets are not worth exec rights next to Authentik's secrets.
- Forgejo backups include the git data directory (`docker/forgejo` on the media share) and a fresh dump of the `forgejo` database. Forgejo is not quiesced: git objects are written before refs are updated, so a push during the backup leaves at most an unreferenced object. Do not add a maintenance window for it without a reason that outweighs the downtime.
- Nextcloud backups include the primary S3 bucket, PostgreSQL dump, and app/config state.
- Maintenance mode covers only the consistency-critical core: the incremental object re-sync, the PostgreSQL dump, and the app-state tar. Object prefetch and the restic upload run with Nextcloud online — never widen the window back to the whole pipeline.
- Every maintenance-mode change is verified against `occ config:system:get maintenance`. A release that cannot be confirmed leaves `/work/maintenance-off.failed` behind and must fail the job; never swallow the error.
- `capture-complete` releases the maintenance mode and must be written on every path out of the capture step, including failures.
- Backup containers mount source volumes read-only. Staging is disposable and remains on-site.
- Weekly verification must check repository data, restore every database dump (Immich, Nextcloud, Forgejo), validate Nextcloud app/config state, and hash-check a restored user-data sample per backup tag. A new backup job is only complete once `verify.sh` and the `validate` container cover it.
- `restic restore` runs with `--exclude-xattr 'security.*'`: the container may not set the SELinux label of the target directory and restic treats that as fatal even though the data is complete.
- Every CronJob here carries the watchdog opt-in labels (`homelab.f4mily.net/watchdog`, `max-age-hours`, `max-runtime-hours`, see `docs/runbooks/job-watchdog.md`); pull `max-age-hours` along whenever `schedule` or `activeDeadlineSeconds` changes.
- No job in this directory may run during the Velero/CNPG backup window (03:45–05:50 Berlin in summer, 02:45–04:50 in winter — Velero and CNPG are UTC-pinned, these jobs are `Europe/Berlin`-pinned). All of them read from TrueNAS `192.168.10.94`, which also hosts the Garage S3 endpoint Velero/CNPG back up to; concurrent load stretches CNPG base backups until Garage expires their multipart upload.

# Work Guidance

- Preserve Nextcloud object IDs and database together; never reconstruct `oc_filecache` from object names.
- Keep Storage Box transfers below its ten-connection limit.
- Run a full isolated application restore after initial seeding and after restore-contract changes.

# Verification

- `just lint`
- `just kustomize-validate`
- Server-side dry-run of decrypted output before merge.

# Child DOX Index

No child AGENTS.md.
