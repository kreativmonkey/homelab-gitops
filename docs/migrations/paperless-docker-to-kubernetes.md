# Paperless Docker to Kubernetes

Goal: run Paperless on the Talos cluster with production data from
`/mnt/Storagepool/Documents/paperless` and database state from
`Migration/paperless/pgdata`.

## GitOps state

- Web UI: `https://paperless.f4mily.net`
- Scanner SMB endpoint: `\\paperless.f4mily.net\Consume`
- SMB credentials: `paperless-ngx-integrations` Secret
- NFS export: `192.168.10.94:/mnt/Storagepool/Documents`
- Paperless subpaths:
  - `paperless/data`
  - `paperless/media`
  - `paperless/export`
  - `paperless/consume`
  - `paperless/redis`

## Cutover

Stop the old Docker stack first so the PostgreSQL data directory and NFS files
stop changing.

Create a dump from the migrated PostgreSQL data directory:

```bash
docker run --rm --name paperless-pg-dump \
  -e POSTGRES_PASSWORD=paperless \
  -v /home/sebastian/git/git.f4mily.net/homelab/Migration/paperless/pgdata:/var/lib/postgresql/data \
  -v /home/sebastian/git/git.f4mily.net/homelab/Migration/paperless:/backup \
  docker.io/library/postgres:16 bash -lc '
    docker-entrypoint.sh postgres &
    until pg_isready -U paperless -d paperless; do sleep 1; done
    pg_dump -U paperless -d paperless -Fc --no-owner --no-acl -f /backup/paperless.dump
  '
```

Restore into the shared CNPG cluster:

```bash
PRIMARY="$(kubectl -n cnpg-system get pods \
  -l cnpg.io/cluster=homelab-postgres,role=primary \
  -o jsonpath='{.items[0].metadata.name}')"

kubectl -n paperless-ngx scale deploy/paperless-ngx --replicas=0

kubectl -n cnpg-system exec -i "$PRIMARY" -- psql -U postgres -d postgres <<'SQL'
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = 'paperless';
DROP DATABASE IF EXISTS paperless;
CREATE DATABASE paperless OWNER paperless;
SQL

kubectl -n cnpg-system exec -i "$PRIMARY" -- \
  pg_restore -U postgres -d paperless --no-owner --role=paperless \
  < /home/sebastian/git/git.f4mily.net/homelab/Migration/paperless/paperless.dump
```

If Flux cannot update existing Paperless PVC/PV objects because old NFS paths are
immutable, delete only the Kubernetes claim objects and let Flux recreate them.
Underlying NFS data is retained.

```bash
kubectl -n paperless-ngx delete pvc \
  paperless-ngx-data paperless-ngx-media paperless-ngx-export redis-data \
  --ignore-not-found

kubectl delete pv \
  pv-nfs-paperless-data pv-nfs-paperless-media \
  pv-nfs-paperless-export pv-nfs-paperless-redis \
  --ignore-not-found

flux reconcile kustomization infrastructure -n flux-system
flux reconcile kustomization apps -n flux-system
kubectl -n paperless-ngx scale deploy/paperless-ngx --replicas=1
```

Verify:

```bash
kubectl -n paperless-ngx get pods,pvc,svc
curl -kI https://paperless.f4mily.net
smbclient -L //paperless.f4mily.net -U paperless
```
