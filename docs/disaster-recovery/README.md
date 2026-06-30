# Homelab disaster recovery

End-to-end recovery after control-plane loss or full cluster rebuild. **PostgreSQL** is restored from S3 (Barman); **Kubernetes workload state** (PVCs, app data) requires Velero or app-level backups unless noted.

## What is covered

| Layer | Mechanism | Doc |
|-------|-----------|-----|
| Talos / etcd / API | Reset CPs, bootstrap, Flux re-apply | [Talos control plane](#talos-control-plane) |
| PostgreSQL | CNPG `bootstrap.recovery` from Garage S3 | [cnpg-s3-dr.md](cnpg-s3-dr.md) |
| App manifests | Flux (`homelab-gitops` on **GitHub**) | This doc |
| PV / namespace data | Velero (optional) | [cnpg-s3-dr.md](cnpg-s3-dr.md#velero-vs-barman) |

## Prerequisites (before you need DR)

1. **CNPG backups** reaching `http://192.168.10.94:30188` — verify `kubectl get backup -n cnpg-system`.
2. **SOPS secrets** in Git decryptable by cluster (`sops-age` in `flux-system` from OpenTofu).
3. **pgadmin**: `pgadmin-credentials.secret.yaml` enabled in `infrastructure/overlays/main/pgadmin/kustomization.yaml` (see `just pgadmin-credentials`).
4. **OpenTofu** access: `homelab-infrastructure/talos` (`kubeconfig`, `talosconfig`, `github_token` for Flux bootstrap).
5. Know that **Flux clones `https://github.com/kreativmonkey/homelab-gitops.git`** — pushes only to Forgejo do not affect the cluster until mirrored to GitHub `main`.

## Talos control plane

Use when API/VIP is down and etcd has no quorum (symptom: `dial tcp 100.96.x.x:2380` or VIP `.245` unreachable).

```bash
cd homelab-infrastructure
nix develop .#talos
export TALOSCONFIG=$PWD/talos/talosconfig

# 1. Reset all control planes (wipes EPHEMERAL / etcd)
for ip in 192.168.10.42 192.168.10.43; do
  talosctl -n $ip -e $ip reset --graceful=false --system-labels-to-wipe EPHEMERAL --reboot
done
talosctl -n 192.168.10.41 -e 192.168.10.41 reset --graceful=false --system-labels-to-wipe EPHEMERAL --reboot

# 2. Wait for nodes, bootstrap etcd on first CP
talosctl -n 192.168.10.41 -e 192.168.10.41 bootstrap

# 3. Re-install Flux + SOPS key (empty cluster)
cd talos && nix develop ..#tofu
tofu apply \
  -target=data.talos_cluster_health.health \
  -target=kubernetes_namespace_v1.flux-system \
  -target=kubernetes_secret_v1.sops_age \
  -target=flux_bootstrap_git.this \
  -auto-approve
```

Verify: `kubectl get nodes`, `talosctl -n 192.168.10.41 -e 192.168.10.41 etcd members` (peer URLs should be `192.168.10.x`, not `100.96.x`).

## CNPG S3 recovery (GitOps)

Follow [cnpg-s3-dr.md](cnpg-s3-dr.md). Summary:

1. `flux suspend kustomization apps -n flux-system`
2. Set `infra-main` path to `./infrastructure/overlays/disaster-recovery` in `clusters/main/infrastructure.yaml`, push **GitHub `main`**.
3. Wait for `homelab-postgres` and `immich-postgres` **Ready**.
4. Revert `infra-main` to `./infrastructure/overlays/main`, push, `flux resume kustomization apps`.

DR patches include `cnpg.io/skipEmptyWalArchiveCheck: enabled` when reusing the same S3 `serverName` as production.

## Post-recovery GitOps pitfalls (2026-05 DR test)

| Issue | Cause | Fix in repo |
|-------|--------|-------------|
| `infra-base` stuck on SUC Deployment | Upstream SUC ≥0.19 uses `strategy: Recreate`; stale `rollingUpdate` after SSA | `patch-deployment-strategy.yaml` |
| `infra-base` stuck on VMServiceScrape | VM operator CRDs not installed yet | Scrapes under `apps/base/monitoring/extra-scrapes/` |
| pgadmin `CreateContainerConfigError` | Secret not in kustomization | Enable `pgadmin-credentials.secret.yaml` |
| pgadmin HelmRelease `Failed` but pod Running | Stale install timeout during DR | `flux reconcile helmrelease pgadmin -n cnpg-system --reset` |
| SUC Deployment invalid (Recreate + rollingUpdate) | SSA merge after DR | Delete Deployment once, or apply `patch-deployment-strategy.yaml` |
| `infra-main` stuck on Certificate | DNS-01 propagation after DR | `infra-main` uses `wait: false`; check `kubectl get challenge -n cert-manager` |
| Flux on old commit | Source is **GitHub**, not Forgejo | `git push origin main` |
| Apps not deploying | `infra-base` not Ready | Fix SUC + reconcile; apps need not wait for all ACME certs |
| Apps dry-run VMRule/VMServiceScrape | VM operator CRDs not installed yet | Rules in `apps-monitoring-rules` Kustomization (after `apps`) |
| PVCs stuck `longhorn-1 not found` | `storageclass.yaml` not in `infra-storage` kustomization | Fixed in `infrastructure/base/storage/kustomization.yaml` |
| Paperless `secret paperless-ngx not found` | App secret not in Git | `apps/overlays/main/paperless-ngx.secret.yaml` (SOPS) |
| UI unreachable via VIP `.245` | Ingress uses `hostNetwork` on node IPs | Use `https://<node-ip>` or DNS to `.41`/`.42`/`.43`, not API VIP |
| `infra-storage` fails on StorageClass `longhorn` | Git must not redefine Helm-owned SC | Only `storageclass-longhorn-1.yaml` in kustomize |
| Longhorn HelmRelease `FailedUpgradePreCheck` (1.6→1.11) | Longhorn allows one minor version per upgrade | [longhorn-upgrade.md](../runbooks/longhorn-upgrade.md) — staged `scripts/longhorn-staged-upgrade.sh` |
| Longhorn/Velero pre-upgrade hook `no route to host` (10.96.0.1:443) on cp1/cp3 | Hook Job scheduled on node without working service CNI/API path | `kubectl cordon talos-cp1 talos-cp3`, delete failed hook Job, retry upgrade |

## Reach apps after rebuild

Ingress NGINX runs as **hostNetwork DaemonSet** on every control-plane node. The API VIP (`192.168.10.245`) is **not** the ingress endpoint.

- Open apps via node IP, e.g. `https://192.168.10.41` with Host header `home.f4mily.net`, or
- Point DNS for `*.f4mily.net` at `192.168.10.41` (or `.42`/`.43`), not `.245`.
- TLS: `wildcard-f4mily.net` cert must be Ready (`kubectl get certificate -n cert-manager`).

## Validate full stack

```bash
export KUBECONFIG=homelab-infrastructure/talos/kubeconfig
flux get kustomizations -A
kubectl get cluster -n cnpg-system
kubectl get pods -A | rg -v 'Running|Completed'
just validate   # from gitops-homelab, nix develop
```

## Optional: reduce blast radius during DR

- Disable heavy apps in `apps/overlays/main/kustomization.yaml` (comment `resources`) before resume.
- Keep **unifi-controller** off if it stresses disk/network during recovery.

## Related

- [Cluster access](../cluster-access.md)
- [CNPG runbook](../runbooks/cnpg-cluster-offline.md)
