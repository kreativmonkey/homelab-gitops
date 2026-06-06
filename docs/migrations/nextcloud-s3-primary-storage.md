# Nextcloud S3 Primary Storage Migration

## Datum
2026-06-06

## Ziel
Migration aller Nextcloud-Benutzerdateien von NFS (lokaler Storage) zu Garage S3 als Primary Storage.

## Hintergrund

Vorher: Nextcloud lief mit:
- App-Code auf iSCSI PVC (`nextcloud-app-iscsi`)
- Benutzerdateien auf NFS PVC (`nextcloud-data`)

Nachher:
- App-Code weiterhin auf iSCSI PVC
- **Alle Dateien in Garage S3** als Primary Storage
- NFS-Datenverzeichnis entfernt

## Wichtige Lektion

**Die `oc_filecache` darf bei S3-Primary-Storage niemals gelöscht werden!**

S3 speichert Dateien als `urn:oid:{fileid}` Blobs ohne jegliche Verzeichnisstruktur. Die Metadaten (Dateinamen, Ordner, Shares) existieren **nur** in der Datenbank-Tabelle `oc_filecache`. Ein `occ files:scan` kann diese Struktur nicht aus S3 rekonstruieren.

## Korrekter Migrationsansatz

Basierend auf [Nextcloud GitHub Issue #25781](https://github.com/nextcloud/server/issues/25781):

1. **Dateien nach S3 kopieren** als `urn:oid:{fileid}` (fileid aus `oc_filecache`)
2. **Nur DB-Tabellen aktualisieren**:
   ```sql
   UPDATE oc_storages SET id = CONCAT('object::user:', SUBSTRING(id FROM 7)) WHERE id LIKE 'home::%';
   UPDATE oc_storages SET id = 'object::store:amazon::nextcloud' WHERE id LIKE 'local::%';
   UPDATE oc_mounts SET mount_provider_class = 'OC\Files\Mount\ObjectHomeMountProvider' 
   WHERE mount_provider_class LIKE '%HomeMountPoint%';
   ```
3. **config.php mit objectstore konfigurieren**
4. **Niemals `files:scan --all` nach Löschen der filecache ausführen!**

## Durchgeführte Schritte

### 1. Vorbereitung
- Backup der Datenbank erstellt (`nextcloud-pre-s3-migration-20260606-093441.dump`)
- S3-Secret erstellt (`nextcloud-s3-credentials`)
- 36.743 S3-Objekte in Garage Bucket `nextcloud` hochgeladen

### 2. Datenbank-Migration
```sql
-- Alte orphaned object storages löschen
DELETE FROM oc_filecache WHERE storage IN (SELECT numeric_id FROM oc_storages WHERE id LIKE 'object::%');
DELETE FROM oc_storages WHERE id LIKE 'object::%';

-- Home storages zu object storages umbenennen
UPDATE oc_storages SET id = 'object::user:admin' WHERE numeric_id = 1;
UPDATE oc_storages SET id = 'object::user:kreativmonkey' WHERE numeric_id = 7;
UPDATE oc_storages SET id = 'object::user:Julia' WHERE numeric_id = 8;
UPDATE oc_storages SET id = 'object::store:amazon::nextcloud' WHERE numeric_id = 2;

-- Mounts aktualisieren
UPDATE oc_mounts SET mount_provider_class = 'OC\Files\Mount\ObjectHomeMountProvider' 
WHERE mount_provider_class LIKE '%HomeMountPoint%';
```

### 3. config.php
```php
'objectstore' => array(
    'class' => '\OC\Files\ObjectStore\S3',
    'arguments' => array(
        'bucket' => 'nextcloud',
        'region' => 'garage',
        'hostname' => '192.168.10.94',
        'port' => '30188',
        'storageClass' => 'STANDARD',
        'objectPrefix' => 'urn:oid:',
        'autocreate' => false,
        'use_ssl' => false,
        'use_path_style' => true,
        'legacy_auth' => false,
        'key' => 'REMOVED_BY_HISTORY_REWRITE',
        'secret' => 'REMOVED_BY_HISTORY_REWRITE',
    ),
),
```

### 4. HelmRelease
- `nextcloud.objectStore.s3.enabled: true` bereits konfiguriert
- NFS `nextcloudData` entfernt
- `image.tag: 33.0.4-apache` gepinnt (Datenversion-Mismatch verhindern)

## Ergebnis

| Storage | Vorher | Nachher |
|---------|--------|---------|
| App-Code | NFS | **iSCSI** |
| Benutzerdateien | NFS | **Garage S3** |
| AppData (Previews) | NFS | **Garage S3** |

- 19.379 Dateien für kreativmonkey migriert
- 70 Dateien für Julia migriert
- 71 Dateien für admin migriert
- 472 Shared-Dateien migriert
- **Keine Daten verloren**

## Bekannte Probleme & Monitoring

### Doppelte Mounts (Automatisch behoben)

**Hintergrund:** Nextcloud hatte bis Version 33 einen Bug, bei dem `ObjectHomeMountProvider` bei jedem Filesystem-Setup einen neuen Mount hinzufügte (siehe [PR #52972](https://github.com/nextcloud/server/pull/52972)). Seit [PR #56933](https://github.com/nextcloud/server/pull/56933) gibt es einen Unique Index auf `oc_mounts`, der Duplikate technisch verhindert.

**Automatische Bereinigung:** Ein Init-Container `cleanup-mounts` läuft bei jedem Pod-Start und entfernt eventuelle Duplikate:
```yaml
- name: cleanup-mounts
  image: docker.io/library/postgres:16-alpine
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

**Manuelle Bereinigung** (falls der Init-Container nicht greift):
```sql
DELETE FROM oc_mounts WHERE id IN (
  SELECT id FROM (
    SELECT id, ROW_NUMBER() OVER (PARTITION BY user_id, mount_point ORDER BY id) as rn
    FROM oc_mounts
  ) t WHERE rn > 1
);
```

### Redis Cache
Nach DB-Änderungen muss Redis geleert werden:
```bash
redis-cli -h nextcloud-redis-master FLUSHDB
```

## Rollback

Falls ein Rollback nötig ist:
1. `config.php`: `objectstore` Block entfernen
2. DB:
   ```sql
   UPDATE oc_storages SET id = CONCAT('home::', SUBSTRING(id FROM 14)) WHERE id LIKE 'object::user:%';
   UPDATE oc_storages SET id = 'local::/var/www/html/data/' WHERE id = 'object::store:amazon::nextcloud';
   UPDATE oc_mounts SET mount_provider_class = 'OC\Files\Mount\HomeMountPoint' 
   WHERE mount_provider_class = 'OC\Files\Mount\ObjectHomeMountProvider';
   ```
3. NFS PVC wieder als `nextcloudData` mounten

## Referenzen

- [Nextcloud Primary Storage Docs](https://docs.nextcloud.com/server/stable/admin_manual/configuration_files/primary_storage.html)
- [GitHub Issue #25781 - Migration from local to S3](https://github.com/nextcloud/server/issues/25781)
- [GeoArchive Migration Script](https://github.com/GeoArchive/nextcloud-S3-local-S3-migration)
