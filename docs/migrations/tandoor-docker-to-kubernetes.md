# Tandoor: Docker (production) → Kubernetes

Migrate the production Tandoor stack (Docker Compose on CephFS) to the homelab cluster
(Flux Deployment, CloudNativePG `homelab-postgres`, NFS static/media PVCs).

**Source reference:** `Migration/tandoor/compose.yml`, `Migration/tandoor/.env` (never commit).

**Target:** `apps/base/tandoor/`, `homelab-infrastructure/dns/servers.tf` (`rezepte` on
`module.talos_cluster` VIP **192.168.10.245**).

## Architecture comparison

| Component | Docker (production) | Kubernetes (homelab) |
|-----------|---------------------|----------------------|
| App | `vabene1111/recipes` (Traefik `recipes.f4mily.net`) | Deployment `tandoor` — `recipes:2.6.9` |
| DB | `postgres:16-alpine` — `djangodb` / `djangouser` | CNPG `homelab-postgres` — DB `tandoor` / role `tandoor` |
| Static | `/mnt/cephfs/tandoor/staticfiles` | PVC `tandoor-static` → NFS `Media` + `subPath: docker/tandoor/staticfiles` |
| Media | `/mnt/cephfs/tandoor/mediafiles` | PVC `tandoor-media` → NFS `Media` + `subPath: docker/tandoor/mediafiles` |
| Ingress | Traefik `recipes.f4mily.net` | NGINX `rezepte.f4mily.net` (wildcard TLS) |
| CSRF | `ALLOWED_HOSTS` only (Traefik TLS) | `CSRF_TRUSTED_ORIGINS=https://rezepte.f4mily.net`, `ALLAUTH_TRUSTED_PROXY_COUNT=2` |
| Auth | Authentik OIDC | Same (`SOCIALACCOUNT_PROVIDERS` in SOPS `tandoor-app`) |

## Prerequisites

- [ ] Export under repo root `Migration/tandoor/` (`postgresql/`, `staticfiles/`, `mediafiles/`).
- [ ] Cluster: `kubectl get database -n cnpg-system homelab-postgres-tandoor`
- [ ] NFS PVCs bound: `tandoor-static`, `tandoor-media` in namespace `tandoor`
- [ ] DNS `rezepte.f4mily.net` → cluster ingress (**192.168.10.245**), not `module.prod` (**192.168.10.244**)
- [ ] Dev shell: `nix develop` (`kubectl`, `pg_dump`, `pg_restore`, `flux`)
- [ ] Maintenance window (Tandoor offline during DB import)

## Phase 0 — SOPS secrets (production parity)

Reuse the production `SECRET_KEY` and Authentik OIDC credentials so sessions and SSO keep working.

```bash
cd apps/base/tandoor
# Values from Migration/tandoor/.env (do not commit plaintext)
just sops-create tandoor-app tandoor \
  SECRET_KEY='<TANDOOR_SECRET_KEY>' \
  SOCIALACCOUNT_PROVIDERS='{"openid_connect":{"APPS":[{"provider_id":"authentik","name":"authentik","client_id":"<AUTHENTIK_CLIENT_ID>","secret":"<AUTHENTIK_CLIENT_SECRET>","settings":{"server_url":"https://login.f4mily.net/application/o/tandoor/.well-known/openid-configuration"}}]}}'
```

Optional mail / AI (from production compose):

```bash
just sops-edit tandoor-app.secret.yaml
# Add keys: EMAIL_HOST_USER, EMAIL_HOST_PASSWORD, AI_API_KEY
```

Commit only the encrypted `tandoor-app.secret.yaml`.

## Phase 1 — Database export from Migration PGDATA

Production Compose used database `djangodb` and user `djangouser`. Export from the copied
`Migration/tandoor/postgresql` directory (PostgreSQL 16):

```bash
REPO_ROOT=/path/to/homelab
PGDATA="$REPO_ROOT/Migration/tandoor/postgresql"
OUT="$REPO_ROOT/Migration/tandoor/tandoor.dump"

docker run --rm \
  -v "$PGDATA:/var/lib/postgresql/data:ro" \
  -e PGDATA=/var/lib/postgresql/data \
  postgres:16-alpine \
  sh -c 'pg_ctl -D /var/lib/postgresql/data -o "-c listen_addresses=" start -w && \
    pg_dump -U djangouser -Fc --no-owner --no-acl djangodb > /tmp/tandoor.dump && \
    pg_ctl -D /var/lib/postgresql/data stop -m fast' \
  && docker cp "$(docker ps -lq):/tmp/tandoor.dump" "$OUT"
```

Verify:

```bash
pg_restore -l "$OUT" | head -20
ls -lh "$OUT"
```

## Phase 2 — Copy static + media to NFS

Scale Tandoor down before writing files:

```bash
kubectl scale deployment/tandoor -n tandoor --replicas=0
```

Use `apps/base/tandoor/migrate-data.job.yaml` (see file header) or rsync from a host with NFS
and CephFS access:

```bash
rsync -avH Migration/tandoor/staticfiles/ /mnt/truenas/Media/docker/tandoor/staticfiles/
rsync -avH Migration/tandoor/mediafiles/  /mnt/truenas/Media/docker/tandoor/mediafiles/
```

## Phase 3 — Restore database into CNPG

```bash
chmod +x scripts/migrations/tandoor-restore-cnpg.sh
./scripts/migrations/tandoor-restore-cnpg.sh Migration/tandoor/tandoor.dump
```

If role names differ, remap owners in pgAdmin or re-run `pg_restore` with `--role=tandoor`.

## Phase 4 — GitOps cutover

1. Merge the Tandoor PR and apply DNS (`just dns::plan` / apply for `rezepte` on talos VIP).
2. Reconcile Flux:

```bash
flux reconcile source git flux-system
flux reconcile kustomization apps --with-source
```

3. Scale up:

```bash
kubectl scale deployment/tandoor -n tandoor --replicas=1
kubectl logs -n tandoor deploy/tandoor -f
```

4. Verify:

```bash
curl -sI https://rezepte.f4mily.net/ | head -5
```

Browser: login via Authentik, open a recipe with image (media PVC).

## Rollback

1. Scale cluster Deployment to 0.
2. Point DNS `rezepte` back to `module.prod` if needed.
3. Start Docker Compose on the production host.

## Related

- [phase1-postgres.md](phase1-postgres.md)
- [nfs-migration.md](nfs-migration.md)
