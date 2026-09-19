# Issue #738 closeout: Garage S3 backup TLS

## Implemented GitOps target

- CNPG production clusters and DR patches for `homelab-postgres`, `immich-postgres`, and `dawarich-postgres` use `https://s3.nas.f4mily.net`.
- Velero uses the same endpoint with `insecureSkipTLSVerify: "false"`; bucket, credentials reference, region, and path-style addressing remain unchanged.
- Nginx Proxy Manager on TrueNAS terminates the public certificate for the endpoint; no in-cluster S3 proxy is deployed.

## Runtime acceptance still open

No Flux reconciliation or production mutation was performed by this change. After reconciliation and authorized operational access, run a manual backup and isolated restore for each CNPG cluster and a Velero backup/download smoke. Nextcloud and the offsite backup script remain HTTP/30188 consumers; do not retire that port until their migration and all restore/download checks pass.
