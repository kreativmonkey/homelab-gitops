# Forgejo: Docker (production) → Kubernetes

Migrate the production Forgejo instance (Docker Compose + Traefik on CephFS) to the
homelab cluster (Flux Kustomize base, NGINX Ingress, NFS data PVC, TCP SSH via
TransportServer).

**Source reference:** `Migration/forgejo/compose.yml`, `Migration/forgejo/gitea/conf/app.ini`.

**Target:** `apps/base/forgejo/`, `infrastructure/base/storage/pv-nfs.yaml` (PV
`pv-nfs-forgejo-data`), `infrastructure/base/network/ingress/helmrelease.yaml`
(GlobalConfiguration TCP listeners on ports **22** and **2222**).

## Architecture comparison

| Component | Docker (production) | Kubernetes (homelab) |
|-----------|---------------------|----------------------|
| App | `codeberg.org/forgejo/forgejo:15` | Deployment `forgejo` — pin in `deployment.yaml` |
| DB | SQLite (`/data/gitea/gitea.db`) | Same file on NFS PVC (no CNPG) |
| Data | `/mnt/cephfs/forgejo` → `/data` | PVC `forgejo-data` → NFS `Media` + `subPath: docker/forgejo` |
| HTTP | Traefik `git.f4mily.net:443` | Ingress `git.f4mily.net` (NGINX, wildcard TLS) |
| Git SSH | Host port `2222` → container `:22` | TransportServer on ingress nodes `:22` and `:2222` → `forgejo-ssh:22` |
| Runner | Docker Swarm `act-runner` | Optional Deployment `forgejo-runner` + DinD (enable after SOPS secret) |
| Renovate | Sidecar container | Not deployed on cluster (keep external or add later) |

## Prerequisites

- [ ] TrueNAS export reachable from cluster (`192.168.10.94:/mnt/Storagepool/Media`).
- [ ] Directory `Media/docker/forgejo` on NAS (create if missing).
- [ ] DNS `git.f4mily.net` → ingress node LAN IPs (**192.168.10.41–43**), not the old Docker host.
- [ ] Maintenance window (Forgejo offline during data rsync).
- [ ] Dev shell: `nix develop` (`kubectl`, `rsync`, `flux`).

## Phase 1 — Prepare NFS data

On the NAS (or from a host with both CephFS and NFS access):

```bash
# Example: rsync production data to TrueNAS path backing pv-nfs-forgejo-data
rsync -avH --delete /mnt/cephfs/forgejo/ /mnt/truenas/Media/docker/forgejo/
```

If CephFS is not mounted locally, use the repo export under `Migration/forgejo/`
(`git/` + `gitea/` only) and copy via a cluster Job on **talos-cp2** (the only
node reachable for `kubectl cp` / `exec` from the operator workstation in this
setup):

```bash
tar -C Migration/forgejo -czf /tmp/forgejo-data.tar.gz git gitea
split -b 100M /tmp/forgejo-data.tar.gz /tmp/forgejo-part-

# Scale forgejo Deployment to 0, then run migrate-data.job.yaml (nodeSelector: cp2)
kubectl apply -f apps/base/forgejo/migrate-data.job.yaml
POD=$(kubectl get pod -n forgejo -l job-name=forgejo-data-migrate -o jsonpath='{.items[0].metadata.name}')
for f in /tmp/forgejo-part-*; do kubectl cp "$f" forgejo/$POD:/tmp/$(basename "$f"); done
kubectl exec -n forgejo "$POD" -- sh -c 'cat /tmp/forgejo-part-* > /tmp/forgejo-data.tar.gz && tar -xzf /tmp/forgejo-data.tar.gz -C /mnt/docker/forgejo'

# Fix ownership (tar via root job leaves root-owned files → s6 lock error)
kubectl apply -f apps/base/forgejo/fix-perms.job.yaml
kubectl wait -n forgejo job/forgejo-fix-perms --for=condition=complete --timeout=600s
kubectl delete job -n forgejo forgejo-data-migrate forgejo-fix-perms
```

**Important:** Do **not** set `runAsUser`/`runAsGroup` on the Forgejo container.
The image drops privileges via s6; forcing UID 1000 causes
`s6-svscan: unable to open .s6-svscan/lock: Permission denied`.

Verify layout (must match container mount `/data`):

```text
docker/forgejo/gitea/conf/app.ini
docker/forgejo/git/repositories/…
```

## Phase 2 — Deploy manifests (GitOps)

Merge the Forgejo PR, then reconcile:

```bash
flux reconcile source git flux-system
flux reconcile kustomization infrastructure --with-source
flux reconcile kustomization apps --with-source
```

Check:

```bash
kubectl get pv pv-nfs-forgejo-data
kubectl get pvc -n forgejo
kubectl get pods,ingress,transportserver -n forgejo
kubectl get globalconfiguration -n ingress-nginx
```

## Phase 3 — Verify HTTP & SSH

**HTTPS**

```bash
curl -sI https://git.f4mily.net/api/healthz
```

**SSH (both ports should accept git@git.f4mily.net)**

```bash
ssh -p 2222 -T git@git.f4mily.net
ssh -p 22   -T git@git.f4mily.net
git ls-remote ssh://git@git.f4mily.net:2222/Homelab/homelab-gitops.git HEAD
```

`app.ini` already sets `SSH_DOMAIN = git.f4mily.net:2222`; port **22** is an
additional entry point via NGINX TCP passthrough (no Forgejo config change needed).

## Phase 4 — Forgejo Actions runner (optional)

1. Forgejo UI → **Administration → Actions → Runners → Create new runner** — copy registration token.
2. Encrypt secret:

```bash
cp apps/base/forgejo/forgejo-runner-register.secret.yaml.template \
   apps/base/forgejo/forgejo-runner-register.secret.yaml
# edit token, then:
sops -e -i apps/base/forgejo/forgejo-runner-register.secret.yaml
```

3. Uncomment in `apps/base/forgejo/kustomization.yaml`:

```yaml
  - runner-deployment.yaml
  - forgejo-runner-register.secret.yaml
```

4. Commit, push, reconcile. Re-register if the old Swarm runner UUID should be retired.

Alternatively copy existing runner state from `Migration/forgejo/runner/data/.runner`
into the runner PVC before first start (skip registration token).

## Phase 5 — Cutover & decommission Docker

1. Stop Docker Compose stack on the old host.
2. Confirm CI (`/.forgejo/workflows/`) and `git push` via SSH work against cluster.
3. Update any hard-coded runner labels if executor changed (DinD vs Swarm).

## Rollback

- Re-point DNS to the Docker host and start Compose.
- Cluster PVC uses `Retain` — data remains on NFS if the Deployment is removed.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| PVC Pending | PV `claimRef` / NAS path | Create `Media/docker/forgejo`, check PV name |
| 502 on HTTPS | Service name / probes | Service must be `forgejo-app`, not `forgejo` |
| SSH timeout | DNS or firewall | Confirm `:22`/`:2222` reach **41–43**, GlobalConfiguration listeners exist |
| TransportServer Rejected | Custom resources off | `controller.enableCustomResources: true` in ingress HelmRelease |
| LFS push fails | Upload limit | Ingress annotations `client-max-body-size: "0"` already set |
