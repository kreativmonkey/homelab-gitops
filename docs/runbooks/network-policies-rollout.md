# Runbook: NetworkPolicies

Standard `networking.k8s.io/v1` NetworkPolicies, enforced by **Cilium**
(ADR 0004, `docs/runbooks/cilium.md`). One CiliumClusterwideNetworkPolicy
covers what NetworkPolicy cannot express (host-network sources).

## Where it lives

```
infrastructure/base/network/network-policies/
├── cluster/           # CCNP allow-from-host-network (entities host + remote-node)
├── baseline/          # Component: default-deny + DNS, same-NS, monitoring
├── egress-external/   # Component: egress 0.0.0.0/0 + ingress VIP/node /32s on 80/443
├── egress-internet/   # Component: like egress-external, minus private/LAN ranges (public apps)
├── egress-database/   # Component: egress → cnpg-system:5432
├── egress-apiserver/  # Component: egress → VIP + CP nodes:6443
├── egress-mail/       # Component: egress 0.0.0.0/0 on 465/587/993
├── <namespace>/       # overlay: sets namespace, picks components, bespoke policies
└── kustomization.yaml # enforced namespaces
```

Reconciled by Flux Kustomization `infra-network-policies`. Not in the tree:
hostNetwork namespaces (`ingress-nginx`, `netbird`, `watchyourlan`; policies
never apply to hostNetwork pods) and `homelable`, `navidrome`, `omni-sync`.

## Cilium semantics (measured 2026-10-16)

- **hostNetwork clients** — ingress-nginx, kube-apiserver (webhooks),
  NetBird — are the entities `host` (same node) or `remote-node` (other node,
  via the tunnel). Selectors and node-IP ipBlocks do not match remote nodes;
  the CCNP `cluster/allow-from-host-network` allows them for every pod
  (`enableDefaultDeny: false`, so it isolates nothing on its own).
- **`0.0.0.0/0` is the `world` entity** and excludes the local host. A pod on
  the node holding the ingress VIP needs explicit /32s for `.245` and the
  node IPs (ingress hairpin) — `egress-external` and the gatus probes carry
  them. Narrower prefixes (e.g. `192.168.10.0/24`) match node IPs
  (`policyCIDRMatchMode: nodes`).
- **ipBlock never matches pod IPs.** Select pods with `namespaceSelector` /
  `podSelector` (monitoring and homepage use `namespaceSelector: {}`).
- **Kubelet probes** are always allowed (local host).
- **`externalIPs` Services** (`paperless-smb`, `mosquitto-external`): the
  LAN client address survives only when the pod runs on the VIP node;
  otherwise the packet arrives SNATed with identity `world`. Allow the port
  from `192.168.10.0/24` **and** `0.0.0.0/0` (missed in audit mode: no client
  connected during the window — MQTT broke for ~2 min after enforcing).
- Cross-namespace flows need **both** sides: egress at the caller and ingress
  at the target.
- Pods without any selecting policy are not isolated.

## Onboarding a namespace

1. Look at the namespace's real traffic in Hubble first (UI
   `https://hubble.cluster.f4mily.net`, or
   `hubble observe --namespace <ns> --last 500`, see `docs/runbooks/cilium.md`).
   Trigger its CronJobs (`kubectl create job --from=cronjob/<name>`) for
   coverage.
2. Write `<ns>/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: <ns>
   components:
     - ../baseline
     # - ../egress-external   # outbound 80/443 (OIDC, web fetch, ingress hairpin)
     # - ../egress-internet   # same, LAN blocked — prefer for internet-exposed apps
     # - ../egress-database   # central CNPG tier (cnpg-system:5432)
     # - ../egress-apiserver  # controller/operator talking to the API
     # - ../egress-mail       # SMTP/IMAP
   # resources:              # bespoke policies (both sides for cross-NS flows)
   #   - allow-egress-<thing>.yaml
   ```
   and add `- <ns>` to `kustomization.yaml`.
3. `just validate`, PR, merge.
4. Watch drops right after Flux applied it:
   `hubble observe --namespace <ns> --verdict DROPPED --follow`. Check its
   ingress host via every node IP from inside the cluster, pod readiness and
   vmagent targets (`up{namespace="<ns>"}`).

For big changes (many namespaces, semantics changes) switch on
`policyAuditMode: true` in the Cilium HelmRelease first: policies are
evaluated and violations show as verdict `AUDIT` in Hubble, nothing is
dropped. Switch it off once `hubble observe --verdict AUDIT` stays quiet.

## Rollback

- One namespace: `kubectl -n <ns> delete netpol default-deny-all` restores
  connectivity at once; Flux re-adds it on the next reconcile, so fix git right
  after.
- Everything: empty the resource list in `kustomization.yaml` and merge (Flux
  prunes). A manual `flux suspend` does **not** hold — `flux-system` resets it
  (`docs/learnings/flannel-to-cilium-migration.md`).
