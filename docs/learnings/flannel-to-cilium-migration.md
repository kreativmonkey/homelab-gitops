# Flannel → Cilium live migration (2026-10-16)

Followed the official per-node procedure
(<https://docs.cilium.io/en/stable/installation/k8s-install-migration/>):
Cilium in secondary mode (own VXLAN port 8473, own pod CIDR 10.245.0.0/16,
`cni.customConf`, `policyEnforcementMode: never`), then per node cordon →
drain → label `io.cilium.migration/cilium-default=true` → restart agent →
reboot (`talosctl reboot` through Omni) → uncordon, cp3 → cp2 → cp1 (CNPG
primaries switched over to migrated nodes before cp1). Pod↔pod across both
overlays worked throughout. Three things went wrong.

## 1. kube-network-policies sidecar dropped host traffic to Cilium pods

**What went wrong:** after the last node switched, ingress-nginx returned 502
for every backend on its own node.

**Why:** the old `kube-flannel` DaemonSet still ran its kube-network-policies
sidecar. It evaluated non-root host traffic to the Cilium pod IPs (source
`cilium_host`) and dropped it. Root traffic (kubelet probes) is exempt there,
so all pods stayed Ready and nothing alerted.

**Correct approach:** remove the old CNI DaemonSet (and its policy sidecar)
as soon as the last node runs Cilium — do not leave it for the cleanup PR.

## 2. Policies came back although their Kustomization was suspended

**What went wrong:** the NetworkPolicy tree had been deleted for the
migration window and `infra-network-policies` / `infra-base` were suspended
with `kubectl patch`. Minutes later all policies were back. Once Cilium
started enforcing, the Flannel-era baseline (host-network sources allowed by
Flannel gateway /32s) matched nothing; ingress-nginx could only reach
backends on its own node — partial outage ~12:37–12:55 UTC.

**Why:** the `flux-system` Kustomization applies
`clusters/main/infrastructure.yaml`, which defines those Kustomizations
without `suspend`, and resets the field. Resuming `flux-system` later briefly
reconciled the old revision again.

**Correct approach:** take things out of the cluster through git (empty the
resource list, merge), not by suspending. If you must suspend, suspend
`flux-system` as well.

## 3. Renovate bumped the CNI mid-migration

**What went wrong:** Cilium went 1.19.9 → 1.20.2 between two migration
steps.

**Why:** the global minor automerge (7-day soak) applied; 1.20.2 was a month
old.

**Correct approach:** Cilium is excluded from automerge (`renovate.json`).

## Prevention

- Measure policy semantics before enforcing: under Cilium, hostNetwork
  sources are `host` / `remote-node`, `0.0.0.0/0` is `world` (excludes the
  local host), ipBlock never matches pods. Roll policy changes out under
  `policyAuditMode` and read Hubble before enforcing.
- Check ingress from **inside** the cluster (a pod curling each node IP) —
  the laptop's NetBird path (fw01) was flaky enough to produce false alarms.
- Keep the Hubble UI / `hubble observe --verdict DROPPED` open during any
  network change.
