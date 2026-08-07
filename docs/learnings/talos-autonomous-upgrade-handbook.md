# Talos Autonomous Upgrade Handbook

**Date**: 2026-07-25
**Updated**: 2026-08-07
**Severity**: high
**Affected**: cluster-wide
**Status**: active guardrail

## What Went Wrong

Five Talos/SUC upgrade rounds needed manual intervention:

- SUC auth/endpoint mistakes left nodes cordoned and jobs failed.
- SUC controller/job anti-affinity and an unpublished controller image tag stalled
  the orchestrator itself.
- CNPG clusters with weak spreading or too few instances blocked drains or caused
  failover storms.
- Node reboots exposed mutable application image drift (`:latest`) and RWO attach
  races, producing NGINX 502s because backend Services had no ready endpoints.
- A fail-closed admission webhook blocked recreation of the rebooted node's CNI
  DaemonSet pods, so the cluster could not rebuild its own networking — cluster-wide
  pod creation stopped until the webhook was relaxed by hand.

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
8. Fail-closed admission control: a webhook with `failurePolicy: Fail` on `CREATE
   pods` and no `kube-system` exemption gates the CNI DaemonSet pods of the node it
   just rebooted. If its backend pod lived on that node it can never come back —
   flannel needs the webhook, the webhook needs flannel. Blast radius is cluster-wide,
   not node-local, and it cascades: replicas that cannot start hold every PDB at
   `disruptionsAllowed: 0`, which then blocks the *next* node's drain.
9. Node-pinned storage plus resource pressure: a `local-path` PV pins its pod to
   exactly one node. If that node lacks CPU or memory *requests* headroom, the pod is
   not delayed — it is permanently unschedulable, because it has no second candidate.

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
- No admission webhook is `failurePolicy: Fail` on core `pods` without a
  `namespaceSelector` excluding `kube-system`. Sidecar injection and label
  enrichment run `Ignore`; only real security gates may fail closed, and those need
  the namespace exemption *and* an HA backend.
- Every webhook backend that gates pod admission runs ≥2 replicas with
  `podAntiAffinity` on `kubernetes.io/hostname`. A singleton can land on the very
  node whose CNI is broken.
- Nodes hosting `local-path` volumes keep real request headroom. A node at >90 % of
  CPU or memory requests cannot restart its own pinned pods after a reboot.

## Upgrade Checklist

Before merging a Talos bump:

```bash
kubectl --context admin@homelab-kube get nodes
kubectl --context admin@homelab-kube -n system-upgrade get deploy,pods,plan,jobs
kubectl --context admin@homelab-kube -n cnpg-system get clusters,pods
rg -n "image:\s*.*:latest|imagePullPolicy:\s*Always" apps infrastructure -g '*.yaml'

# no fail-closed webhook may gate pod creation in kube-system (failure class 8)
kubectl --context admin@homelab-kube get mutatingwebhookconfiguration,validatingwebhookconfiguration -o json | jq -r '
  .items[].webhooks[] | select(.failurePolicy=="Fail")
  | select([.rules[]?.resources[]?] | index("pods"))
  | "RISK \(.name) namespaceSelector=\(.namespaceSelector)"'

# every node must have request headroom for its own pinned pods (failure class 9)
kubectl --context admin@homelab-kube describe nodes | rg -A5 'Allocated resources' | rg '^\s+(cpu|memory)'
```

Do not merge while any of these is true: a webhook shows up as `RISK` without a
`kube-system` exemption, a node is above ~90 % of CPU or memory requests, or any
stateful cluster is below its full instance count. All three turn a routine drain
into a stall.

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
- If `FailedCreate ... failed calling webhook` appears on a DaemonSet or ReplicaSet,
  stop diagnosing the workload — the cluster cannot create pods at all. Relax the
  webhook, then let the chain heal itself in order (CNI → operators → stateful
  replicas → PDB → drain):

  ```bash
  kubectl patch mutatingwebhookconfiguration <name> \
    --type=json -p '[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
  ```

  Revert to `Fail` only after the durable fix (namespace exemption + HA backend) is
  in Git; a live patch is drift and will be reconciled away.
- After relaxing the webhook, expect the DaemonSet controller to wait out its
  `failedPodsBackoff` — up to 15 minutes, and it does **not** reset when the cause
  disappears. Confirm ordinary pods are being created again, then wait instead of
  deleting objects.
- Counting readiness with `grep -v Running` is wrong: a pod stuck at `0/1 Running`
  matches and is silently counted as healthy. Compare the READY column instead:

  ```bash
  kubectl get pods -A --no-headers \
    | awk '{split($3,a,"/"); if (a[1]!=a[2] && $4!="Completed") print $1"/"$2"  "$3"  "$4}'
  ```

## Prevention

- Treat Talos upgrades as node-drain tests for every stateful workload.
- Keep mutable-image checks part of every Talos bump review.
- Prefer pinned app tags with Renovate PRs over silent pull-on-reboot updates.
- Treat every newly installed operator as a possible admission-control change: check
  what webhooks its chart ships before it reaches `main`, not after a reboot exposes
  them. Chart defaults are not validated for this cluster.
- Anything the cluster needs in order to repair itself — CNI, kube-proxy, CoreDNS,
  CSI — must not depend on a workload that can be down. That is the general form of
  failure class 8, and it is worth checking against any new cluster-wide gate.
- Hypervisor CPU/RAM changes need a full VM stop/start. Proxmox marks `cores`/
  `sockets` edits on a running VM as *pending*; `talosctl reboot` keeps the same
  qemu process and the node returns with the old capacity. Use `talosctl shutdown`,
  start the VM, verify `capacity.cpu`, one node at a time.
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
