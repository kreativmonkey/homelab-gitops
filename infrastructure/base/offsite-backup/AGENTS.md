# Purpose

Encrypted offsite backups of irreplaceable Immich, Nextcloud, and Forgejo data to the Hetzner Storage Box. This is the primary protection for volume data — Velero keeps Kubernetes objects, CNPG keeps databases locally for fast restores.

# Ownership

- Owns: Storage Box credentials, Restic repository jobs, Nextcloud backup staging, restore verification, and namespace-scoped backup RBAC.
- Parent `infrastructure/AGENTS.md` owns cluster-wide storage and backup policy.

# Local Contracts

- Storage Box credentials and Restic password stay SOPS-encrypted in `storagebox-credentials.secret.yaml`.
- Restic is the durable backup format; rclone only exposes the SFTP target and stages Nextcloud S3 objects.
- Immich backups include `Bilder`, `Fotos`, and a fresh PostgreSQL dump.
- Forgejo backups include the git data directory (`docker/forgejo` on the media share) and a fresh dump of the `forgejo` database. Forgejo is not quiesced: git objects are written before refs are updated, so a push during the backup leaves at most an unreferenced object. Do not add a maintenance window for it without a reason that outweighs the downtime.
- Nextcloud backups include the primary S3 bucket, PostgreSQL dump, and app/config state.
- Maintenance mode covers only the consistency-critical core: the incremental object re-sync, the PostgreSQL dump, and the app-state tar. Object prefetch and the restic upload run with Nextcloud online — never widen the window back to the whole pipeline.
- Every maintenance-mode change is verified against `occ config:system:get maintenance`. A release that cannot be confirmed leaves `/work/maintenance-off.failed` behind and must fail the job; never swallow the error.
- `capture-complete` releases the maintenance mode and must be written on every path out of the capture step, including failures.
- Backup containers mount source volumes read-only. Staging is disposable and remains on-site.
- Weekly verification must check repository data, restore every database dump (Immich, Nextcloud, Forgejo), validate Nextcloud app/config state, and hash-check a restored user-data sample per backup tag. A new backup job is only complete once `verify.sh` and the `validate` container cover it.
- `restic restore` runs with `--exclude-xattr 'security.*'`: the container may not set the SELinux label of the target directory and restic treats that as fatal even though the data is complete.
- Every CronJob here carries the watchdog opt-in labels (`homelab.f4mily.net/watchdog`, `max-age-hours`, `max-runtime-hours`, see `docs/runbooks/job-watchdog.md`); pull `max-age-hours` along whenever `schedule` or `activeDeadlineSeconds` changes.

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
