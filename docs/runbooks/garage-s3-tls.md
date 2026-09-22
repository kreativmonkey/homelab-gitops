# Garage S3 TLS endpoint

## Contract

| Item | Value |
| --- | --- |
| Client endpoint | `https://s3.nas.f4mily.net` |
| Client trust | Public WebPKI; verification required |
| TLS termination | Nginx Proxy Manager on TrueNAS |
| Garage HTTP listener | `192.168.10.94:30188` (retained for existing consumers) |

Nginx Proxy Manager on TrueNAS presents the publicly trusted certificate for `s3.nas.f4mily.net` and proxies S3 traffic to Garage. No in-cluster proxy or TrueNAS Caddy origin is required.

## Validation and retirement

Validate endpoint SNI and certificate verification before migration. Do not expose or remove the existing HTTP/30188 path in this change: Nextcloud and `infrastructure/base/offsite-backup/scripts.configmap.yaml` remain consumers until their separate migration and CNPG/Velero restore validation complete.

## Critical: proxy target must be the S3 API, not the web UI

The NPM proxy host `s3.nas.f4mily.net` must forward to Garage's **S3 API**
(`192.168.10.94:30188`), never to Garage's web UI port. On 21.09.2026 the
proxy was misconfigured to the web UI; barman-cloud and Velero received HTML
instead of S3 XML and WAL archiving/backups silently failed for ~24h (see
[cnpg-wal-archiving-stalled.md](cnpg-wal-archiving-stalled.md)).

Verify with:

```bash
curl -sS -D - "https://s3.nas.f4mily.net/cnpg-backups?list-type=2&max-keys=1"
```

Expect `content-type: application/xml`; `text/html` means the proxy target is wrong.
