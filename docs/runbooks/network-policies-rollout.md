# Runbook: NetworkPolicies

Standard `networking.k8s.io/v1` NetworkPolicies are **enforced** since
2026-10-16 (ADR 0003). The CNI stays Flannel; Talos runs
[kube-network-policies](https://kube-network-policies.sigs.k8s.io/) as a
sidecar in the `kube-flannel` DaemonSet.

## Engine

- Switched on in `infrastructure/base/omni-sync/cluster-template.yaml`
  (ControlPlane patch `200-flannel-network-policies`,
  `KubeFlannelCNIConfig.kubeNetworkPoliciesEnabled: true`). Talos only creates
  bootstrap manifests; omni-sync's `manifest-sync` rolls DaemonSet changes out.
- nftables + NFQUEUE, verdicts in userspace. Only packets to/from pods selected
  by some policy are queued; accepted connections get a conntrack label and
  skip the queue afterwards.
- **Fail-open**: if the sidecar is down, traffic passes unfiltered.
- Only `NetworkPolicy`. AdminNetworkPolicy/BaselineAdminNetworkPolicy need a
  different image flavor and are not enforced.
- Talos hard-codes `--v=2`: every evaluated packet is logged. vlagent drops the
  container (`excludeFilter`); read verdicts on the node:
  ```bash
  kubectl -n kube-system logs <kube-flannel-pod> -c kube-network-policies --since=10m \
    | grep -B4 'verdict="drop"'
  ```

## Semantics that bit us

- **hostNetwork sources never match a selector.** ingress-nginx, kube-apiserver
  (webhooks) and NetBird reach pods from the node: source `10.244.X.1` (cni0,
  same node) or `10.244.X.0` (flannel.1, other node), not the node IP. The
  baseline `allow-from-host-network` lists these /32s per node pod CIDR —
  **update it when a node is replaced** (`kubectl get nodes -o
  jsonpath='{..podCIDR}'`).
- **Kubelet probes are exempt** (uid 0 on the local node).
- **`externalIPs` Services keep the LAN client IP** when the backend runs on
  the VIP node (`paperless-smb`, `mosquitto-external`) — they need an explicit
  `192.168.10.0/24` ingress rule.
- **A newly selected pod loses its open connections once.** Established
  connections without the engine's conntrack label are re-evaluated; replies
  (e.g. from the apiserver) count as new ingress and are dropped, clients
  reconnect. The observer step below avoids this.
- Cross-namespace flows need **both** sides: egress at the caller and ingress
  at the target.
- Policies never apply to hostNetwork pods: `ingress-nginx`, `netbird`,
  `watchyourlan` stay out of the tree.

## Where it lives

```
infrastructure/base/network/network-policies/
├── baseline/          # Component: default-deny + DNS, host-network, same-NS, monitoring
├── egress-external/   # Component: egress 0.0.0.0/0 on 80/443
├── egress-database/   # Component: egress → cnpg-system:5432
├── egress-apiserver/  # Component: egress → VIP + CP nodes:6443
├── egress-mail/       # Component: egress 0.0.0.0/0 on 465/587/993
├── <namespace>/       # overlay: sets namespace, picks components, bespoke policies
└── kustomization.yaml # enforced namespaces, in batches
```

Reconciled by Flux Kustomization `infra-network-policies`
(`clusters/main/infrastructure.yaml`).

## Onboarding a namespace

Measure first, then enforce. Tools in `scripts/netpol/`.

1. **Observe.** Apply an allow-all policy so the engine logs every new
   connection without blocking, and stream the verdict logs:
   ```bash
   kubectl -n <ns> apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: {name: observe-allow-all}
   spec: {podSelector: {}, policyTypes: [Ingress, Egress], ingress: [{}], egress: [{}]}
   EOF
   scripts/netpol/collect.sh /tmp/netpol-obs      # leave running
   ```
   Let it run long enough to cover the namespace's jobs; trigger CronJobs
   manually (`kubectl create job --from=cronjob/<name>`) for coverage.
2. **Write the overlay** (`<ns>/kustomization.yaml`, components + bespoke
   policies) and add the namespace to `kustomization.yaml`.
3. **Replay** the observed flows against the rendered policies; it prints
   every flow that would be dropped:
   ```bash
   kubectl get pods -A -o json | jq -c '[.items[] | {ns:.metadata.namespace, name:.metadata.name, labels:(.metadata.labels//{}), ports:[.spec.containers[].ports[]? | {name:.name, port:.containerPort, proto:(.protocol//"TCP")}]}]' > /tmp/netpol-obs/pods.json
   kubectl get ns -o json | jq -c '[.items[] | {name:.metadata.name, labels:(.metadata.labels//{})}]' > /tmp/netpol-obs/ns.json
   kustomize build infrastructure/base/network/network-policies > /tmp/netpol-obs/rendered.yaml
   python3 scripts/netpol/simulate.py /tmp/netpol-obs/rendered.yaml /tmp/netpol-obs
   ```
   Fix until it prints nothing you want to keep working.
4. PR, merge. Flux applies the policies — no effect yet, the observer still
   allows everything.
5. **Enforce**: `kubectl -n <ns> delete netpol observe-allow-all`. Then check
   ingress hosts via every node IP, pod readiness and drop verdicts (log
   command above).

## Rollback

- One namespace: `kubectl -n <ns> delete netpol default-deny-all` (Flux re-adds
  it on the next reconcile — `flux suspend kustomization infra-network-policies`
  first if it must stay off).
- All policies: suspend `infra-network-policies`, delete the policies, fix in
  git.
- Engine: revert the cluster-template patch and let manifest-sync apply. Check
  that the `kube-network-policies` container is gone from `kube-flannel`
  (untested); with fail-open, a stopped sidecar already lets traffic pass.
