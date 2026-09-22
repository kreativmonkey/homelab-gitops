# CNPG WAL archiving stalled

## Symptom

Alert `CNPGWALArchivingStalled` or `CNPGWALArchivingCritical` — WAL segments
are piling up unarchived on a CNPG instance pod.

More urgent than `CNPGBackupStale`: that alert only fires after 50h without a
successful backup. WAL archiving can be broken for a full day before it does,
during which unarchived segments accumulate on node-local storage (no
iSCSI/Longhorn buffer) and can push a node toward disk pressure.

## Checks

Confirm the cluster condition:

```bash
kubectl get cluster.postgresql.cnpg.io <name> -n cnpg-system -o jsonpath='{.status.conditions}'
```

Look for `ContinuousArchiving` with `status: "False"`.

Measure the backlog (0 is normal; sustained growth means archiving is stuck):

```promql
cnpg_collector_pg_wal_archive_status{namespace="cnpg-system",value="ready"}
```

Check the instance logs for `barman-cloud-wal-archive` errors:

```bash
kubectl logs -n cnpg-system <instance-pod> -c postgres --tail=200 | grep barman-cloud-wal-archive
```

## First suspect: is the S3 endpoint actually the S3 API?

```bash
curl -sS -D - "https://s3.nas.f4mily.net/cnpg-backups?list-type=2&max-keys=1"
```

Expected: `content-type: application/xml` and an S3 `<Error>` document
(anonymous `403 AccessDenied` is correct). If `content-type: text/html` comes
back instead, the proxy is pointing at the Garage web UI, not the S3 API —
this is exactly the incident from 21.09.2026.

## Remediation

Point the NPM proxy host `s3.nas.f4mily.net` at the Garage S3 API
(`192.168.10.94:30188`), not the web UI port. See
[garage-s3-tls.md](garage-s3-tls.md).

## Follow-up

Backup CRs stuck in non-terminal phases (`pending`, `walArchivingFailing`)
from the outage window do not resolve on their own and block the next
scheduled run. Delete them once `.status.startedAt` and `.status.backupId`
are both empty (no data was ever written to object storage):

```bash
kubectl get backup -n cnpg-system
kubectl delete backup -n cnpg-system <stuck-backup-name>
```

Then trigger a verification backup and confirm it completes.
