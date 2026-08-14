# Purpose

Encrypted offsite backups of irreplaceable Immich and Nextcloud data to the Hetzner Storage Box.

# Ownership

- Owns: Storage Box credentials, Restic repository jobs, Nextcloud backup staging, restore verification, and namespace-scoped backup RBAC.
- Parent `infrastructure/AGENTS.md` owns cluster-wide storage and backup policy.

# Local Contracts

- Storage Box credentials and Restic password stay SOPS-encrypted in `storagebox-credentials.secret.yaml`.
- Restic is the durable backup format; rclone only exposes the SFTP target and stages Nextcloud S3 objects.
- Immich backups include `Bilder`, `Fotos`, and a fresh PostgreSQL dump.
- Nextcloud backups run in maintenance mode and include the primary S3 bucket, PostgreSQL dump, and app/config state.
- Backup containers mount source volumes read-only. Staging is disposable and remains on-site.
- Weekly verification must check repository data, restore both database dumps, validate Nextcloud app/config state, and hash-check restored Immich and Nextcloud user-data samples.
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
