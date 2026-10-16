# ADR 0003: Enforce NetworkPolicies with Flannel + kube-network-policies

- Status: accepted
- Date: 2026-10-16
- Supersedes: ADR 0002
- PRs: #1177, #1179, #1180, #1182 and the infra batch

## Context

ADR 0002 kept the NetworkPolicy tree as inert declarations because Flannel
does not enforce policies and the only route considered was a Cilium
migration (CNI swap, outage window, rollback rehearsal).

Since Talos 1.13, the Flannel bootstrap manifests can run
sigs.k8s.io/kube-network-policies as a sidecar
(`KubeFlannelCNIConfig.kubeNetworkPoliciesEnabled`). The CNI, pod network and
kube-proxy stay untouched; the engine is fail-open and removable by flipping
the flag back.

## Decision

Enable kube-network-policies on the existing Flannel CNI via the Omni cluster
template and enforce the standard NetworkPolicy tree.

The tree was written for Cilium and never enforced, so it was re-onboarded in
batches. Before each batch an allow-all observer policy made the engine log
real traffic, and the observed flows were replayed against the rendered
policies (`scripts/netpol/`). Procedure and gotchas:
`docs/runbooks/network-policies-rollout.md`.

## Consequences

- Pod-to-pod and egress isolation is now an active control for the namespaces
  in the tree. Namespaces outside it (and hostNetwork pods) stay open.
- Host-network sources (ingress-nginx, apiserver webhooks, NetBird) are
  allowed by per-node Flannel gateway /32s in the baseline; node replacement
  must update them.
- Only `NetworkPolicy`; no AdminNetworkPolicy, no L7 or FQDN rules. If those
  become necessary, the Cilium path from ADR 0002 remains the option.
- Every new or changed workload flow needs a matching policy, on both sides
  for cross-namespace traffic.
- Talos forces per-packet logging (`--v=2`); vlagent excludes the container.
