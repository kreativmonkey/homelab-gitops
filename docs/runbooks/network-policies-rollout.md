# Runbook: NetworkPolicy rollout

Default-deny NetworkPolicies are rolled out **per namespace, phased** — never
big-bang. The cluster runs Cilium, which honours standard
`networking.k8s.io/v1` NetworkPolicies, so we deliberately use the portable
resource (not `CiliumNetworkPolicy`).

## Where it lives

```
infrastructure/base/network/network-policies/
├── baseline/            # Kustomize Component: the always-safe policy set
│   ├── 00-default-deny.yaml          # deny all ingress + egress
│   ├── 10-allow-dns.yaml             # egress → CoreDNS (kube-system)
│   ├── 20-allow-from-ingress-nginx.yaml
│   ├── 30-allow-same-namespace.yaml
│   └── 40-allow-from-monitoring.yaml # ingress ← vmagent (scrape)
├── egress-external/     # Component: add-on, egress to the internet on 80/443
│   └── 50-allow-egress-external.yaml
├── <namespace>/         # per-namespace overlay (sets namespace, picks components)
└── kustomization.yaml   # bundles the per-namespace overlays
```

Reconciled by the **`infra-network-policies`** Flux Kustomization
(`clusters/main/infrastructure.yaml`), separate from `infra-base` so a rollback
is a single `flux suspend kustomization infra-network-policies`.

## Phase 1 pilot

| Namespace | Components | Why |
|-----------|------------|-----|
| `homer`   | baseline | static dashboard, no backend, no egress |
| `linkding`| baseline + egress-external | SQLite, but OIDC → login.f4mily.net (443) |
| `readeck` | baseline + egress-external | SQLite, but archives web pages (80/443) |

## Onboarding another namespace

1. **Map the namespace's real traffic first** — what does it need to reach?
   - DNS, ingress-nginx, intra-namespace, monitoring scrape → already covered by `baseline`.
   - Outbound HTTP/HTTPS (OIDC, web fetch) → add the `egress-external` component.
   - Central **CNPG database** in another namespace → add a bespoke
     `allow-egress-database` policy in the namespace overlay (egress to the DB
     namespace on 5432). Most cross-namespace DB users live in
     `apps/overlays/main/databases/`.
   - Other cross-namespace calls (Redis, Authentik internal, MQTT) → add a
     matching egress policy.
2. Create `network-policies/<ns>/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: <ns>
   components:
     - ../baseline
     # - ../egress-external   # only if it needs outbound 80/443
   ```
3. Add `- <ns>` to `network-policies/kustomization.yaml`.
4. `just validate`, commit, push.
5. **Verify before moving on** (see below). Onboard one or two namespaces per PR.

## Verification after reconcile

```bash
kubectl -n <ns> get networkpolicy                 # the set is present
kubectl -n <ns> get pods                          # app still Running/Ready
# app still reachable through its ingress (curl the public host)
# vmagent target still UP:
#   Grafana → Explore → up{namespace="<ns>"}  == 1
# DNS works from inside a pod:
kubectl -n <ns> exec deploy/<app> -- nslookup login.f4mily.net
```

If a flow is wrongly blocked: `kubectl -n <ns> delete networkpolicy default-deny-all`
restores connectivity instantly while you fix the allow rule (Flux re-adds it on
next reconcile — `flux suspend` the Kustomization first if you need it to stay off).

## Rollback (whole pilot)

```bash
flux suspend kustomization infra-network-policies
kubectl delete networkpolicy -n homer -n linkding -n readeck --all
```
or revert the commit and let Flux prune.
