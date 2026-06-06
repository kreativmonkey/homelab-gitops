#!/usr/bin/env python3
"""
Nextcloud local -> S3 primary storage migration script.
Dry-run safe: set DRY_RUN=1 to test without uploading.
"""
import os
import sys
import time

DRY_RUN = int(os.environ.get('DRY_RUN', 1))

UUID_TO_USER = {
    '11bc164e-7711-4b5f-8060-19d9eda8f463': 'kreativmonkey',
    '3aadebcd-7773-439d-bd10-5701e3984bc0': 'Julia',
}

def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

def connect_db():
    import psycopg2
    db = psycopg2.connect(
        host=os.environ['DB_HOST'],
        database=os.environ['DB_NAME'],
        user=os.environ['DB_USER'],
        password=os.environ['DB_PASSWORD']
    )
    db.autocommit = True
    return db

def connect_s3():
    import boto3
    from botocore.config import Config
    s3_config = Config(
        retries={'max_attempts': 3, 'mode': 'standard'},
        connect_timeout=10,
        read_timeout=30
    )
    return boto3.client(
        's3',
        endpoint_url=os.environ['S3_ENDPOINT'],
        aws_access_key_id=os.environ['S3_ACCESS_KEY'],
        aws_secret_access_key=os.environ['S3_SECRET_KEY'],
        region_name=os.environ['S3_REGION'],
        config=s3_config
    )

def build_source_path(storage_id, path):
    nfs_base = '/mnt/nfs'
    if storage_id.startswith('home::'):
        user = storage_id.split('::', 1)[1]
        if path:
            source = os.path.join(nfs_base, user, path)
            if os.path.exists(source):
                return source
            mapped = UUID_TO_USER.get(user)
            if mapped:
                return os.path.join(nfs_base, mapped, path)
            return source
        source = os.path.join(nfs_base, user)
        if os.path.exists(source):
            return source
        mapped = UUID_TO_USER.get(user)
        if mapped:
            return os.path.join(nfs_base, mapped)
        return source
    elif storage_id.startswith('local::'):
        if path:
            return os.path.join(nfs_base, path)
        return nfs_base
    return None

def storage_exists_on_disk(storage_id):
    nfs_base = '/mnt/nfs'
    if storage_id.startswith('home::'):
        user = storage_id.split('::', 1)[1]
        if os.path.exists(os.path.join(nfs_base, user)):
            return True
        mapped = UUID_TO_USER.get(user)
        if mapped and os.path.exists(os.path.join(nfs_base, mapped)):
            return True
        return False
    elif storage_id.startswith('local::'):
        return os.path.exists(nfs_base)
    return False

def migrate():
    db = connect_db()
    cur = db.cursor()
    s3 = connect_s3()
    bucket = os.environ['S3_BUCKET']

    log("Fetching file list from database...")
    cur.execute("""
        SELECT s.id, f.fileid, f.path, f.size
        FROM oc_filecache f
        JOIN oc_storages s ON f.storage = s.numeric_id
        WHERE (s.id LIKE 'home::%%' OR s.id LIKE 'local::%%')
        AND f.mimetype != 2
        ORDER BY f.fileid
    """)
    rows = cur.fetchall()

    valid_rows = [r for r in rows if storage_exists_on_disk(r[0])]
    total_files = len(valid_rows)
    skipped_storages = len(rows) - total_files
    log(f"Files to migrate: {total_files} (skipped {skipped_storages} entries from non-existent storages)")

    uploaded = 0
    skipped = 0
    errors = 0
    total_bytes = 0
    start_time = time.time()

    for idx, (storage_id, fileid, path, size) in enumerate(valid_rows, 1):
        source = build_source_path(storage_id, path)
        if not source or not os.path.exists(source):
            skipped += 1
            continue

        s3_key = f'urn:oid:{fileid}'

        if DRY_RUN:
            log(f"[{idx}/{total_files}] DRY-RUN: {source} -> {s3_key} ({size} bytes)")
        else:
            try:
                s3.head_object(Bucket=bucket, Key=s3_key)
                uploaded += 1
            except:
                try:
                    s3.upload_file(source, bucket, s3_key)
                    uploaded += 1
                    total_bytes += size if size and size > 0 else 0
                except Exception as e:
                    log(f"ERROR uploading {source}: {e}")
                    errors += 1

        if idx % 100 == 0:
            elapsed = time.time() - start_time
            rate = idx / elapsed if elapsed > 0 else 0
            log(f"Progress: {idx}/{total_files} | Uploaded: {uploaded} | Skipped: {skipped} | Errors: {errors} | Rate: {rate:.1f} files/s")

    elapsed = time.time() - start_time
    log(f"Migration complete: {uploaded} uploaded, {skipped} skipped, {errors} errors in {elapsed:.0f}s")

    if not DRY_RUN and errors == 0:
        log("Updating database storage mappings...")
        cur.execute("""
            UPDATE oc_storages
            SET id = 'object::store:amazon::nextcloud'
            WHERE id LIKE 'local::%%'
        """)
        cur.execute("""
            UPDATE oc_storages
            SET id = 'object::user:' || substring(id from 7)
            WHERE id LIKE 'home::%%'
        """)
        cur.execute("""
            UPDATE oc_mounts
            SET mount_provider_class = 'OC\Files\Mount\ObjectHomeMountProvider'
            WHERE mount_provider_class LIKE '%%LocalHomeMountProvider%%'
        """)
        log("Database updated successfully")

    cur.close()
    db.close()

if __name__ == '__main__':
    try:
        migrate()
    except Exception as e:
        log(f"FATAL: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
