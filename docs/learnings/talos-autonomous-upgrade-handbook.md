# Talos Autonomous Upgrade Handbook

**Date**: 2026-07-25
**Severity**: high
**Affected**: cluster-wide
**Status**: active guardrail

## What Went Wrong

Four Talos/SUC upgrade rounds needed manual intervention:

- SUC auth/endpoint mistakes left nodes cordoned and jobs failed.
- SUC controller/job anti-affinity and an unpublished controller image tag stalled
  the orchestrator itself.
- CNPG clusters with weak spreading or too few instances blocked drains or caused
  failover storms.
- Node reboots exposed mutable application image drift (`:latest`) and RWO attach
  races, producing NGINX 502s because backend Services had no ready endpoints.

## Why It Failed

Talos does a clean node upgrade: cordon, drain, reboot, rejoin, uncordon. That is
correct, but it means every cluster workload must tolerate one node leaving at a
time. SUC is only the runner; it does not know this homelab's storage, CNPG,
Ingress, or app startup dependencies.

The repeated failure classes were:

1. Wrong Talos API mode: `--insecure` only fits maintenance mode, not running nodes.
2. Wrong Talos endpoint: authenticated `talosctl` needs explicit `-e` and `-n`
   node IPs; localhost/Unix socket fails certificate validation.
3. SUC self-block: Plan labels are copied to jobs, so job labels must not match
   controller anti-affinity selectors.
4. Bad controller pin: controller manifest ref and image tag must both exist and
   match; cached layers hide broken tags until a reboot.
5. Drain blockers: single-instance or co-located stateful workloads make PDBs and
   RWO volumes fight the drain.
6. Mutable images: `:latest` and `imagePullPolicy: Always` turn a Talos reboot into
   an unreviewed app upgrade.
7. Slow recovery fan-out: after all nodes reboot, iSCSI attach, image pulls, DB
   readiness, and OIDC discovery cascade; NGINX 502 usually means no ready backend,
   not broken NGINX.

## The Correct Approach

Keep the SUC Plan boring and explicit:

```yaml
spec:
  concurrency: 1
  cordon: true
  serviceAccountName: system-upgrade
  jobActiveDeadlineSecs: 3600
  secrets:
    - name: talosconfig
      path: /var/run/secrets/talos.dev
  drain:
    force: true
    ignoreDaemonSets: true
    deleteLocalData: true
    timeout: 600s
  upgrade:
    image: ghcr.io/siderolabs/talosctl:vX.Y.Z
    envs:
      - name: NODE_IP
        valueFrom:
          fieldRef:
            fieldPath: status.hostIP
    command: [/talosctl]
    args:
      - --talosconfig=/var/run/secrets/talos.dev/talosconfig
      - -e
      - $(NODE_IP)
      - -n
      - $(NODE_IP)
      - upgrade
      - --image=factory.talos.dev/nocloud-installer/<schematic>:$(SYSTEM_UPGRADE_PLAN_LATEST_VERSION)
      - --drain=false
      - --wait=false
      - --timeout=15m
```

Hard requirements for this repo:

- `concurrency: 1`; no `exclusive: true`.
- Talos Plan labels use `app.kubernetes.io/name: talos-upgrade`, never the
  controller's app name.
- SUC controller anti-affinity matches `app.kubernetes.io/component=controller`.
- SUC kustomize manifest `?ref=` and `images.newTag` stay identical and published.
- `talos-plan.yaml` version, talosctl image tag, installer image tag, and Terraform
  `talos_version`/schematic stay in sync.
- CNPG clusters that must survive autonomous drains have at least two instances,
  `podAntiAffinityType: required`, and `failoverDelay: 30`.
- DB storage stays node-local `local-path`; iSCSI is acceptable for app RWO data,
  but those apps need `Recreate` strategy or chart-equivalent single-writer behavior.
- No production app image uses `:latest`; avoid `imagePullPolicy: Always` unless
  there is a documented reason.

## Upgrade Checklist

Before merging a Talos bump:

```bash
kubectl --context admin@homelab-kube get nodes
kubectl --context admin@homelab-kube -n system-upgrade get deploy,pods,plan,jobs
kubectl --context admin@homelab-kube -n cnpg-system get clusters,pods
rg -n "image:\s*.*:latest|imagePullPolicy:\s*Always" apps infrastructure -g '*.yaml'
```

After SUC starts:

```bash
kubectl --context admin@homelab-kube -n system-upgrade get plan talos -w
kubectl --context admin@homelab-kube get nodes -w
kubectl --context admin@homelab-kube get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

If Ingress shows 502, check backend readiness first:

```bash
kubectl --context admin@homelab-kube -n ingress-nginx logs \
  -l app.kubernetes.io/name=nginx-ingress --since=20m --tail=200
kubectl --context admin@homelab-kube get endpointslices -A | rg '<service-name>'
kubectl --context admin@homelab-kube describe pod -n <namespace> <pod>
```

## Recovery Rules

- If SUC is stuck and any node is cordoned, pause SUC first:
  `kubectl -n system-upgrade scale deploy/system-upgrade-controller --replicas=0`.
- Uncordon before CNPG repair; CNPG may freeze while a primary sits on an
  unschedulable node.
- Re-clone diverged CNPG replicas by deleting pod + PVC; do not repair WAL-ahead
  replicas by hand.
- For RWO `Multi-Attach`, verify Deployment strategy. Patch live to `Recreate` only
  as emergency unblock, then fix Git.
- For post-reboot 502s, wait through normal iSCSI attach/image-pull startup, but
  investigate CrashLoopBackOff immediately.

## Prevention

- Treat Talos upgrades as node-drain tests for every stateful workload.
- Keep mutable-image checks part of every Talos bump review.
- Prefer pinned app tags with Renovate PRs over silent pull-on-reboot updates.
- Keep one canonical upgrade handrail here; incident-specific learnings remain
  historical evidence.

## Related

- [talos-automatic-upgrade-suc-auth.md](talos-automatic-upgrade-suc-auth.md)
- [cnpg-failover-storm-soft-antiaffinity.md](cnpg-failover-storm-soft-antiaffinity.md)
- [goloom-rwo-upgrade-race.md](goloom-rwo-upgrade-race.md)
- [democratic-csi-pvc-resize-permission-denied.md](democratic-csi-pvc-resize-permission-denied.md)
- [netbird-reverse-proxy-traefik-grpc-timeout.md](netbird-reverse-proxy-traefik-grpc-timeout.md)
- [Sidero Talos upgrade docs](https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/lifecycle-management/upgrading-talos)
- [Rancher System Upgrade Controller](https://github.com/rancher/system-upgrade-controller)
