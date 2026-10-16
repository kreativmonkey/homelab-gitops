# ADR 0004: Cilium as CNI

- Status: accepted
- Date: 2026-10-16
- Supersedes: ADR 0003
- PRs: #1186, #1189, #1192, #1194, #1195, #1196 and the docs/enforcement follow-ups

## Context

ADR 0003 enforced NetworkPolicies with the kube-network-policies sidecar on
Talos-default Flannel. It works for plain NetworkPolicy, but leaves gaps that
ADR 0002 had already listed as Cilium triggers: no FQDN egress (most policies
allow `0.0.0.0/0:443`), no policy for host-network pods, policy debugging only
by reading per-packet sidecar logs, and host-network sources only matchable
by brittle per-node gateway /32s.

## Decision

Replace Flannel with Cilium, migrated live with Cilium's per-node dual-overlay
procedure. Cilium is a Flux HelmRelease (`infrastructure/base/network/cilium/`)
with its own Flux Kustomization; Talos' Flannel is deleted in the Omni
template. kube-proxy stays (`kubeProxyReplacement: false`) to stay clear of
open Talos + KPR issues. Hubble (relay + UI behind Authentik) is the policy
debugging tool.

## Consequences

- Pod CIDR is `10.245.0.0/16`, VXLAN on 8473 (migration leftovers).
- The NetworkPolicy tree runs under Cilium semantics; host-network sources
  are allowed by one CiliumClusterwideNetworkPolicy
  (`docs/runbooks/network-policies-rollout.md`).
- Flux cannot repair a broken CNI; emergency reinstall and fresh-cluster
  bootstrap need a manual `helm template | kubectl apply`
  (`docs/runbooks/cilium.md`).
- Cilium is excluded from Renovate automerge.
- Open options, each a separate decision: kube-proxy replacement, FQDN
  egress policies, host firewall, eBPF host routing
  (`bpf.hostLegacyRouting: false`).
