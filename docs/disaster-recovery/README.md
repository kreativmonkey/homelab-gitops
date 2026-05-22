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
- Keep **uptime-kuma** / **unifi-controller** off if they stress disk/network during recovery.

## Related

- [Cluster access](../cluster-access.md)
- [CNPG runbook](../runbooks/cnpg-cluster-offline.md)
