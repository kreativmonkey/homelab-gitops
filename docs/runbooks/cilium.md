# Runbook: Cilium (CNI)

Cilium is the CNI since 2026-10-16 (ADR 0004). It replaced the Talos-default
Flannel live, node by node; how that went: `docs/learnings/flannel-to-cilium-migration.md`.

## Setup

- Flux HelmRelease `kube-system/cilium` in `infrastructure/base/network/cilium/`,
  reconciled by its own Flux Kustomization `infra-cilium` (depends only on
  `infra-sources`).
- Talos side (Omni template, ControlPlane patch `200-disable-flannel`):
  `KubeFlannelCNIConfig` deleted. kube-proxy stays (nftables mode);
  `kubeProxyReplacement: false`.
- Agent talks to the API through KubePrism (`localhost:7445`).
- Overlay: VXLAN on UDP **8473**, pod CIDR **10.245.0.0/16** (`cluster-pool`,
  /24 per node). Both are leftovers of the dual-overlay migration; changing
  them means re-IPing every pod.
- `policyCIDRMatchMode: [nodes]`: ipBlocks also match node IPs.
- Hubble relay + UI; UI at `https://hubble.cluster.f4mily.net` behind
  Authentik (proxy provider on the embedded outpost, admins only).
- `rollOutCiliumPods` / `operator.rollOutPods`: a `cilium-config` change rolls
  the agents (DaemonSet `maxUnavailable: 2` — brief datapath restarts, existing
  connections survive).
- Renovate does **not** automerge Cilium (`renovate.json`). Read the release
  notes and Talos compatibility before merging a bump.

## Health

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-health status
# drops on one node (no hubble needed):
kubectl -n kube-system exec <cilium-pod> -c cilium-agent -- cilium-dbg monitor --type drop
```

Hubble CLI (cluster-wide):

```bash
kubectl -n kube-system port-forward svc/hubble-relay 4245:80 &
nix shell nixpkgs#hubble -c hubble --server localhost:4245 observe --verdict DROPPED --follow
nix shell nixpkgs#hubble -c hubble --server localhost:4245 observe --namespace <ns> --last 200
```

`UNSUPPORTED_L3_PROTOCOL` drops are IPv6 link-local multicast from pods
(IPv6 is off) — ignore. `STALE_OR_UNROUTABLE_IP` are packets to pods that
just went away.

## Gotchas

- **Flux cannot heal its own CNI.** If Cilium is broken, Flux (and every other
  pod) has no network. Emergency reinstall from a laptop:
  ```bash
  yq '.spec.values' infrastructure/base/network/cilium/helmrelease.yaml > /tmp/cilium-values.yaml
  helm repo add cilium https://helm.cilium.io && helm template cilium cilium/cilium \
    --version <version from helmrelease.yaml> -n kube-system -f /tmp/cilium-values.yaml \
    | kubectl apply --server-side -f -
  ```
  A freshly bootstrapped cluster has no CNI (Flannel is disabled in the Omni
  template) — run the same command before bootstrapping Flux.
- **A manual `flux suspend` of an infra Kustomization does not hold.** The
  `flux-system` Kustomization re-applies `clusters/main/infrastructure.yaml`
  and resets `spec.suspend`. Suspend `flux-system` too, or change git.
- **hostNetwork clients** (ingress-nginx, kube-apiserver, NetBird) are the
  entities `host` / `remote-node`, never a pod or namespace; see
  `docs/runbooks/network-policies-rollout.md`.
- Node replacement: nothing to update for Cilium (node pod CIDRs come from
  the operator pool, not from the node object).
