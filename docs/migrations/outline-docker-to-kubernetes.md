# Outline: Docker (production) → Kubernetes

Migrate the production Outline stack (Docker Compose on dedicated host) to the homelab
cluster (Flux HelmRelease, CloudNativePG `homelab-postgres`, iSCSI PVC).

**Source reference:** `Migration/outline_ea/compose.yaml`, `Migration/outline_ea/env`

**Target:** `apps/base/outline/`, `homelab-infrastructure/dns/servers.tf` (`outline` on
`module.talos_cluster` VIP **192.168.10.245**).

## Architecture comparison

| Component | Docker (production) | Kubernetes (homelab) |
|-----------|---------------------|----------------------|
| App | `outlinewiki/outline` (Traefik `outline.f4mily.net`) | HelmRelease `outline` — Community Chart 0.8.0 |
| DB | `postgres:16` – `outline` / `user` | CNPG `homelab-postgres` — DB `outline` / role `outline` |
| Redis | `redis` standalone | Built-in Bitnami Redis subchart (no persistence) |
| Uploads | `./storage-data/uploads` auf Docker-Host | PVC `outline-app` → `truenas-iscsi` 5Gi RWO |
| Ingress | Traefik `outline.f4mily.net` | NGINX `outline.f4mily.net` (wildcard TLS) |
| Auth | OIDC via Authentik | Same (OIDC config in HelmRelease values) |
| SMTP | `mail.f4mily.net:465` | Same |

## Prerequisites

- [ ] Export under repo root `Migration/outline_ea/` (`database-data/`, `storage-data/uploads/`).
- [ ] Cluster: `kubectl get database -n cnpg-system homelab-postgres-outline`
- [ ] Dev shell: `nix develop` (`kubectl`, `pg_dump`, `pg_restore`, `flux`)
- [ ] SOPS-encrypted Secrets erstellt (siehe Phase 0)
- [ ] DNS `outline.f4mily.net` → cluster ingress (**192.168.10.245**), nicht alter Docker-Host
- [ ] Maintenance window (Outline offline während DB-Import)

## Phase 0 — SOPS secrets

### 1. App-Secrets (SECRET_KEY, UTILS_SECRET, OIDC, SMTP)

Die Werte stehen in `Migration/outline_ea/env`.

```bash
cd apps/base/outline
# 1. Template mit den Werten aus env befüllen (bereits erledigt)
# 2. Mit SOPS verschlüsseln:
sops --encrypt --age $(cat $SOPS_AGE_KEY_FILE.pub) outline-config.secret.yaml.template > outline-config.secret.yaml
# 3. Template NICHT committen
```

### 2. DB-Credentials

Nachdem der CNPG `Database` CR (in `apps/overlays/main/databases/outline.yaml`) deployed ist,
generiert CNPG automatisch einen Secret mit Username/Password. Diesen müssen wir in die
SOPS-verschlüsselte `outline-db-credentials.secret.yaml` übernehmen:

```bash
# 1. Nach Flux-Sync das CNPG-generierte Secret holen:
kubectl get secret -n cnpg-system homelab-postgres-outline -o jsonpath='{.data.password}' | base64 -d

# 2. Ausgabe kopieren
# 3. SOPS-Secret entschlüsseln und Passwort ersetzen:
cd apps/overlays/main/db-secrets
sops outline-db-credentials.secret.yaml   # öffnet Editor
# → password Wert durch das CNPG-Passwort ersetzen, speichern + schließen
```

## Phase 1 — Database export from Migration PGDATA

Die alte PostgreSQL 16-Installation hat ihre Daten in `Migration/outline_ea/database-data/`.

```bash
REPO_ROOT=/home/sebastian/git/git.f4mily.net/homelab
PGDATA="$REPO_ROOT/Migration/outline_ea/database-data"
OUT="$REPO_ROOT/Migration/outline.dump"

docker run --rm \
  -v "$PGDATA:/var/lib/postgresql/data:ro" \
  -e PGDATA=/var/lib/postgresql/data \
  postgres:16 \
  sh -c 'pg_ctl -D /var/lib/postgresql/data -o "-c listen_addresses=" start -w && \
    pg_dump -U user -Fc --no-owner --no-acl outline > /tmp/outline.dump && \
    pg_ctl -D /var/lib/postgresql/data stop -m fast' \
  && docker cp "$(docker ps -lq):/tmp/outline.dump" "$OUT"
```

Verify:

```bash
pg_restore -l "$OUT" | head -20
ls -lh "$OUT"
```

## Phase 2 — Restore in CNPG

Die CNPG-Datenbank läuft auf `homelab-postgres-rw.cnpg-system.svc.cluster.local`.

```bash
# 1. Port-Forward zum CNPG-Cluster:
kubectl port-forward -n cnpg-system service/homelab-postgres-rw 5432:5432 &

# 2. Passwort aus dem CNPG-Secret holen:
PGPASSWORD=$(kubectl get secret -n cnpg-system homelab-postgres-outline -o jsonpath='{.data.password}' | base64 -d)

# 3. Restore:
pg_restore -h localhost -U outline -d outline --no-owner --no-acl -v "$OUT"

# 4. Verbindung testen:
PGPASSWORD="$PGPASSWORD" psql -h localhost -U outline -d outline -c "\dt"
```

**Wichtig:** `--no-owner` und `--no-acl` weil der CNPG `outline`-Role eine andere OID hat
als der alte Docker-Postgres-User.

## Phase 3 — Uploads auf PVC kopieren

```bash
# PVC ist nach HelmRelease-Deployment vorhanden
kubectl get pvc -n outline

# Pod identifizieren:
POD=$(kubectl get pods -n outline -l app.kubernetes.io/name=outline -o jsonpath='{.items[0].metadata.name}')

# Migration uploads in den PVC kopieren:
kubectl cp "$REPO_ROOT/Migration/outline_ea/storage-data/uploads/." "$POD:/var/lib/outline/data/uploads/"
```

## Phase 4 — DNS und Go-Live

```bash
# 1. DNS-Eintrag für outline.f4mily.net prüfen/aktualisieren:
#    homelab-infrastructure/dns/servers.tf → module.talos_cluster
#    Hostname muss auf 192.168.10.245 (VIP) zeigen, nicht auf alten Docker-Host.
cd "$REPO_ROOT/../homelab-infrastructure"
nix develop .#tofu
cd dns
just dns::plan

# 2. Wenn DNS-Umstellung nötig: just dns::apply

# 3. Outline testen: https://outline.f4mily.net
```

## Rollback

Falls etwas schiefgeht:

1. Outline deaktivieren: `apps/overlays/main/kustomization.yaml` — `../../base/outline` auskommentieren
2. Flux sync: `flux reconcile kustomization apps --with-source`
3. Alte Docker-Compose-Instanz wieder starten
