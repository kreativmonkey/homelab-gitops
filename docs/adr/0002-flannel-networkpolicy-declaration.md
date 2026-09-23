# ADR 0002: Retain Flannel; keep NetworkPolicies declarative until enforcement is required

- Status: accepted
- Date: 2026-09-22
- Issue: #981
- Related: #983 corrects the NetworkPolicy rollout runbook's stale Cilium claim

## Context

The cluster uses Flannel v0.28.4. Flannel does not enforce Kubernetes
`networking.k8s.io/v1` `NetworkPolicy` resources. The repository's policy tree
at `infrastructure/base/network/network-policies/` is therefore a declarative
future policy model, not an active isolation boundary.

The tree includes default-deny policies. Applying, reconciling, or claiming
those policies as enforced without first changing the CNI would create a false
security assertion. A default-deny policy must not be added or broadened as a
response to this decision.

This is a single-tenant homelab. The present operational benefit of enforced
pod-level isolation does not justify a CNI migration outage and the full
validation work it requires.

## Decision

Retain Flannel. Keep the existing standard Kubernetes NetworkPolicies as
portable, non-enforcing declarations for future use. Do not make a CNI change,
apply new default-deny policies, or represent the policy tree as an active
security control.

Issue #983 owns the correction of the rollout runbook and other operational
wording that states or assumes Cilium enforcement.

## Alternative considered: migrate to Cilium

Cilium would be the selected implementation if enforcement becomes necessary,
because it enforces standard Kubernetes NetworkPolicies and allows a later,
separate decision about Cilium-specific policy features. This remains a future
migration, not an approved change.

A migration proposal must include all of the following before it can be
approved:

1. Talos MachineConfig ownership in the infrastructure repository. CNI,
   kube-proxy replacement settings, installation method, version pin, and
   recovery configuration must be declarative and reviewable. Do not install
   Cilium imperatively into a Flux-managed cluster.
2. A maintenance window with user-visible outage expectation. Workloads,
   ingress, DNS, pod networking, and network-dependent controllers can lose
   connectivity while the CNI transitions.
3. A tested rollback to the exact prior Flannel Talos MachineConfig and
   Kubernetes state. The rollback plan must state node order, expected outage,
   health gates, and how to recover a node that does not rejoin.
4. A canary node/control-plane validation before fleet rollout, followed by
   staged node replacement or reboot according to the Talos-supported CNI
   migration procedure for the installed Talos and Kubernetes versions.
5. Revalidation of every namespace after Cilium is healthy. Start with the
   existing policy inventory in `infrastructure/base/network/network-policies/`;
   reconcile one or two namespaces at a time and prove DNS, ingress, service
   dependencies, database access, monitoring scrape paths, backups, CSI, and
   application-specific external egress. Do not call a repository render or a
   policy object's presence evidence of enforcement.
6. An explicit host-network review. `ingress-nginx`, `netbird`,
   `watchyourlan`, and system-upgrade workloads use host networking or host
   mounts; standard Kubernetes NetworkPolicies do not automatically provide
   their desired host isolation. Their Talos host firewall and privileged
   access model must be reviewed separately.

## Triggers to revisit

Open a Cilium migration decision when any one of these conditions is true:

- the cluster becomes multi-tenant or workloads from different trust domains
  share a namespace, node pool, or network;
- an exposed workload, security review, or incident identifies enforced
  pod-to-pod or egress isolation as a required mitigation;
- compliance, insurance, or a documented threat model requires enforceable
  NetworkPolicies;
- a new workload cannot be safely deployed without egress allow-listing or
  namespace isolation; or
- an approved operational project has capacity for the Talos-owned migration,
  maintenance window, rollback rehearsal, and namespace-by-namespace
  validation above.

A trigger opens a new implementation proposal; it does not authorize a direct
CNI mutation or a default-deny rollout.

## Consequences

- Existing standard NetworkPolicies remain source-controlled design input and
  can be rendered and schema-validated.
- They provide no current traffic enforcement under Flannel and must not be
  cited as a compensating control.
- Current isolation relies on workload configuration, Kubernetes RBAC,
  namespace boundaries, ingress exposure controls, Talos host security, and
  network perimeter controls.
- The runbook correction is intentionally separated in #983 so it can update
  all operational references consistently.
