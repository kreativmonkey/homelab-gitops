# Authentik: Docker (production) → Kubernetes

Migrate production Authentik (`login.f4mily.net` on Docker Swarm / prod host) to the
homelab cluster (HelmRelease, CloudNativePG `homelab-postgres`, NGINX ingress).

**Source:** `Migration/authentik/` (PGDATA, media, compose-stack.yml).

**Target:** `apps/base/authentik/`, Database `homelab-postgres-authentik`.

## Architecture

| Component | Docker (production) | Kubernetes |
|-----------|---------------------|------------|
| App | `ghcr.io/goauthentik/server:2025.12.4` | Helm chart `2025.12.4` |
| DB | Postgres 16 (bind mount PGDATA) | CNPG `homelab-postgres` / DB `authentik` |
| Redis | Docker volume | In-cluster Bitnami Redis (ephemeral) |
| Media | `/mnt/cephfs/authentik/media` | PVC `authentik-media` |
| Ingress | Traefik `login.f4mily.net` | NGINX `login.f4mily.net` |

## Prerequisites

- CNPG cluster Ready: `kubectl get cluster -n cnpg-system homelab-postgres`
- NodePort restore: `homelab-postgres-restore` → **30433** (control-plane LAN IP)
- Production `AUTHENTIK_SECRET_KEY` must match cluster secret (SOPS or live patch)
- Maintenance window — Authentik offline during DB import

## Phase 1 — Export from Migration PGDATA

If you have a logical dump already, skip to Phase 2.

```bash
PGDATA=/path/to/Migration/authentik/database
nix shell nixpkgs#postgresql_16 --command bash -c "
  pg_ctl -D '$PGDATA' -o '-p 55432 -h 127.0.0.1 -k /tmp' -l /tmp/authentik-pg.log start
  PGPASSWORD='<prod-db-password>' pg_dump -h 127.0.0.1 -p 55432 -U authentik \
    -Fc --no-owner --no-acl authentik > /tmp/authentik.dump
  pg_ctl -D '$PGDATA' stop
"
```

## Phase 2 — Import into CNPG

```bash
export KUBECONFIG=homelab-infrastructure/talos/kubeconfig
kubectl scale deployment -n authentik authentik-server authentik-worker --replicas=0

CNPG_PASS=$(kubectl get secret -n authentik homelab-postgres-authentik -o jsonpath='{.data.password}' | base64 -d)
NODE_IP=192.168.10.41   # any control-plane node

# If DB was dropped: recreate via CNPG Database CR
kubectl apply -f apps/overlays/main/databases/authentik.yaml

pg_restore -h "$NODE_IP" -p 30433 -U authentik -d authentik \
  --no-owner --no-acl --clean --if-exists /tmp/authentik.dump
```

Verify:

```bash
psql -h "$NODE_IP" -p 30433 -U authentik -d authentik \
  -c "SELECT COUNT(*) FROM authentik_core_user;"
```

## Phase 3 — Secret key and media

**Secret key** (required — decrypts stored credentials; must be ASCII, same as Docker production):

```bash
cd apps/base/authentik
just sops-create authentik-secret-key authentik \
  secret-key='<AUTHENTIK_SECRET_KEY from Migration/authentik/compose-stack.yml>'
```

See also: [authentik-upgrade-2026.md](./authentik-upgrade-2026.md) for version upgrades.

**Media** (icons, uploads):

```bash
POD=$(kubectl get pod -n authentik -l app.kubernetes.io/name=authentik,app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}')
kubectl cp Migration/authentik/media/. authentik/"$POD":/media/
```

## Phase 4 — Production cutover (GitOps)

1. `cluster-config.yaml`: `host_authentik: login.f4mily.net`
2. Ingress TLS → `publicTlsSecret` (`wildcard-f4mily-net-tls`)
3. DNS: `login.f4mily.net` → cluster VIP (`homelab-infrastructure/dns/servers.tf`)
4. Remove GitOps OAuth blueprints (production DB is authoritative)
5. `terraform apply` DNS + `flux reconcile kustomization apps`

## Phase 5 — Validate

- https://login.f4mily.net/ → login with existing production user
- OAuth apps (Grafana, Immich, …) — redirect URIs unchanged if hostname stays `login.f4mily.net`
- Outposts: Docker-based outposts from production need re-deployment (K8s/LDAP/proxy outposts)

## Rollback

Re-enable Docker stack on prod; restore AdGuard rewrite `login.f4mily.net` → `192.168.10.244`.
