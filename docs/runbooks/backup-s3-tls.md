# Backup S3 TLS runbook

## Contract

CNPG and Velero use `https://s3.nas.f4mily.net` with public-WebPKI verification. Nginx Proxy Manager on TrueNAS terminates the public certificate and proxies to Garage. No in-cluster proxy is part of this path.

Never set `insecureSkipTLSVerify: "true"`. A private CA requires an explicit trust-distribution design before client migration.

## Rollout and acceptance

1. Verify DNS, SNI, hostname, and certificate chain:

```bash
openssl s_client -connect s3.nas.f4mily.net:443 -servername s3.nas.f4mily.net \
  -verify_hostname s3.nas.f4mily.net -verify_return_error </dev/null
```

2. Reconcile the CNPG patches and Velero HelmRelease only after the endpoint passes verification.
3. For each of `homelab-postgres`, `immich-postgres`, and `dawarich-postgres`, create a manual CNPG backup and restore it to a temporary isolated Cluster; inspect status/logs and delete the temporary Cluster.
4. Create a narrowly scoped Velero backup, verify BSL `Available`, download and inspect the artifact, then delete the smoke backup.

No runtime smoke was performed by this repository change. A certificate, hostname, or SNI failure blocks rollout; fix it rather than bypassing verification.

## HTTP retirement

Nextcloud remains a separate direct HTTP consumer of `192.168.10.94:30188`. Do not remove or firewall HTTP/30188 until Nextcloud migration and all CNPG/Velero acceptance checks have completed. Emergency HTTP rollback requires explicit security approval, a fixed end time, and documented restoration of HTTPS verification.
