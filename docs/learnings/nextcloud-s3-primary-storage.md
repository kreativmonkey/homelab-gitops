# Nextcloud: NFS → S3 Primary Storage Migration

**Date**: 2026-06-06
**Severity**: critical
**Affected**: apps/base/nextcloud
**Status**: resolved

## What Went Wrong

Attempted to migrate Nextcloud from NFS to S3 primary storage using a simple `occ files:scan --all` after reconfiguring `config.php`. This approach:
- **Deleted `oc_filecache`** entries (via `files:scan --all` with broken S3 config), causing all file metadata to disappear
- **Created duplicate `oc_mounts` entries** because `ObjectHomeMountProvider` re-registered on every filesystem setup
- **Lost file shares** because file IDs changed when the scanner regenerated them
- **Required DB restore** from pre-migration backup to recover

Initial assumption: S3 bucket + `files:scan` would re-index files into object storage. Reality: S3 stores only `urn:oid:{fileid}` blobs; the filecache is the sole source of truth for filenames, paths, and metadata.

## Why It Failed

1. **S3 object storage ≠ filesystem**: Nextcloud's S3 primary storage stores raw blob data (`urn:oid:{fileid}`) in the bucket. The `oc_filecache` table maps these opaque object IDs to human-readable filenames and directory structures. Deleting filecache entries breaks this mapping permanently.

2. **`files:scan --all` is dangerous with S3**: When the S3 configuration is not yet active in the database (only in `config.php`), the scanner operates on the old storage backend, sees files as "new", and regenerates IDs — orphaning S3 objects.

3. **Duplicate mounts bug**: Nextcloud <33 had a bug where `ObjectHomeMountProvider::setup()` added a new mount on every call without checking for existing entries ([PR #52972](https://github.com/nextcloud/server/pull/52972)). Fixed in Nextcloud 33 via a unique index on `oc_mounts` ([PR #56933](https://github.com/nextcloud/server/pull/56933)).

4. **Image tag mismatch**: The Helm chart default image (`33.0.3-apache`) conflicted with the existing database data version (`33.0.4.1`), causing a fatal "upgrade required" error on pod startup.

## The Correct Approach

### 1. Do NOT delete `oc_filecache`

The filecache is sacred. Never run `occ files:scan --all` during an S3 migration. The existing file IDs must be preserved.

### 2. Migrate data directly to S3 bucket

Upload existing files from NFS to S3 using the `urn:oid:{fileid}` naming convention:
```python
# Key insight: S3 objects must be named exactly "urn:oid:{fileid}"
# where {fileid} matches the existing oc_filecache.fileid
s3.put_object(
    Bucket='nextcloud',
    Key=f'urn:oid:{fileid}',
    Body=file_content
)
```

### 3. Update database storage references only

```sql
-- Rename storage backend in oc_storages
UPDATE oc_storages
SET id = 'object::user:' || uid
WHERE id LIKE 'home::%';

-- Update mount provider
UPDATE oc_mounts
SET mount_provider_class = 'OC\\Files\\Mount\\ObjectHomeMountProvider'
WHERE mount_provider_class = 'OC\\Files\\Mount\\HomeMountProvider';
```

### 4. Configure `config.php` with objectstore block

```php
'objectstore' => array(
    'class' => 'OC\\Files\\ObjectStore\\S3',
    'arguments' => array(
        'bucket' => 'nextcloud',
        'autocreate' => true,
        'key' => '...',
        'secret' => '...',
        'hostname' => '192.168.10.94',
        'port' => 30188,
        'use_ssl' => false,
        'use_path_style' => true,
        'legacy_auth' => false,
    ),
),
```

### 5. Pin image tag to match database version

```yaml
nextcloud:
  image:
    tag: "33.0.4-apache"  # Must match existing data version
```

### 6. Defensive cleanup for duplicate mounts

Add an init container to clean up any duplicate `oc_mounts` entries on pod startup:
```yaml
initContainers:
  - name: cleanup-mounts
    image: docker.io/library/postgres:16-alpine
    envFrom:
      - secretRef:
          name: homelab-postgres-nextcloud
    command:
      - sh
      - -c
      - |
        psql -h "${PGHOST}" -U "${PGUSER}" -d "${PGDATABASE}" -c "
          DELETE FROM oc_mounts
          WHERE id IN (
            SELECT id FROM (
              SELECT id, ROW_NUMBER() OVER (
                PARTITION BY user_id, mount_point ORDER BY id
              ) as rn FROM oc_mounts
            ) t WHERE rn > 1
          );
        "
```

## Prevention

1. **Always backup the database** before storage migration:
   ```bash
   pg_dump -h <host> -U <user> -d nextcloud > /backup/nextcloud-pre-migration.dump
   ```

2. **Verify S3 objects match file IDs** before switching the storage backend. Upload and spot-check:
   ```bash
   aws s3 ls s3://nextcloud/ | grep "urn:oid:"
   ```

3. **Test with one user first** — migrate a single user's files, verify WebDAV access, then proceed with remaining users.

4. **Never run `occ files:scan --all` on S3-primary instances** unless the storage backend is fully configured and verified.

5. **Check Nextcloud version compatibility** between Helm chart default and existing database data version before any upgrade or reconfiguration.

## Related

- [Migration Documentation](../migrations/nextcloud-s3-primary-storage.md)
- HelmRelease: `apps/base/nextcloud/helmrelease.yaml`
- S3 Secret: `apps/base/nextcloud/nextcloud-s3-credentials.secret.yaml`
- Migration Script: `apps/base/nextcloud/migrate-local-to-s3.py`
