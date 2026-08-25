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
├── egress-database/     # Component: egress → cnpg-system:5432 (CNPG tier)
│   └── allow-egress-database.yaml
├── egress-apiserver/    # Component: egress → API server VIP + CP nodes:6443
│   └── allow-egress-apiserver.yaml
├── egress-mail/         # Component: egress → 0.0.0.0/0 on 465/587/993 (mail)
│   └── allow-egress-mail.yaml
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

## Phase 2 (issue #739)

| Namespace | Components | Why / extra egress |
|-----------|------------|-----|
| `authentik` | baseline + egress-external + egress-database + egress-mail | IdP: postgres (CNPG), SMTP 465, error reporting 443 |
| `cnpg-system` | baseline + egress-external + egress-apiserver + `allow-ingress-postgres` + `allow-ingress-webhook` | operator→API (egress) + webhook ingress from API server; DB ingress `5432` from **any** namespace (auth-gated) |
| `forgejo` | baseline + egress-external + egress-database | postgres (CNPG), redis in-ns, webhooks/avatars/OIDC |
| `immich` | baseline + egress-external + egress-database | postgres (CNPG), valkey in-ns, ML model download (443) |
| `nextcloud` | baseline + egress-external + egress-database + egress-mail + `allow-egress-s3-garage` | postgres, redis in-ns, Garage S3 `192.168.10.94:30188/30190`, mail, OIDC |
| `monitoring` | baseline + egress-external + egress-apiserver + `allow-egress-cluster` | vmagent scrapes pod CIDR `10.244.0.0/16` + node CIDR `192.168.10.0/24`; kubernetes_sd → API |
| `gatus` | baseline + `allow-egress-probe-dns` + `allow-egress-probes` | prober forces DNS via `192.168.10.1`/`1.1.1.1` and hits external + `*.f4mily.net` on 80/443 |

### Gotchas when onboarding the DB / observability tiers
- **`cnpg-system` is special.** Default-deny there blocks (a) the operator's
  API-server watch → add `egress-apiserver`, (b) admission **webhook ingress**
  from the API server → `allow-ingress-webhook` (VIP `192.168.10.245` + CP
  nodes `192.168.10.41-43`), (c) client connections from app NS →
  `allow-ingress-postgres` opens `5432` to **all** namespaces (DB is
  credential-gated; acceptable tradeoff for the tier). Replication between
  instances and WAL→S3 are covered by baseline same-ns + `egress-external`.
- **`monitoring` must reach pod *and* node IPs.** vmagent scrapes
  `kubernetes_sd` endpoints (pod CIDR) plus kubelet/node-exporter (node CIDR),
  and needs the API server for SD. `allow-egress-cluster` opens both CIDRs;
  Grafana/Alertmanager external (OIDC, ntfy) use `egress-external`.
- **`gatus` bypasses CoreDNS.** Its config points DNS at the LAN router
  (`192.168.10.1`) and Cloudflare (`1.1.1.1`), so the baseline `allow-dns`
  (CoreDNS only) is insufficient — add `allow-egress-probe-dns`.
- **Apps on CNPG** (authentik, immich, forgejo, nextcloud, …) just add the
  `egress-database` component; the matching **ingress** already lives in
  `cnpg-system` (point c above).

## Phase 3 (issue #739, remaining app NS — Batch A, DONE)

14 low-risk app namespaces rolled out with only baseline + component-driven
egress (no bespoke policies needed):

| Namespace | Components | Why |
|-----------|------------|-----|
| `ai-agents` | baseline | placeholder NS, no workloads yet (covers first deploy) |
| `audiobookshelf` | baseline + egress-external | optional cover/metadata fetch |
| `jellyfin` | baseline + egress-external | external metadata providers |
| `kavita` | baseline + egress-external | optional metadata fetch |
| `searxng` | baseline + egress-external | upstream search engines |
| `workshops` | baseline + egress-external | git-sync clones git.f4mily.net |
| `sterling-pdf` | baseline | local Ghostscript/LibreOffice only |
| `dawarich` | baseline + egress-database + egress-external | CNPG + OIDC |
| `goloom` | baseline + egress-database + egress-external | CNPG + OIDC |
| `paperless-ngx` | baseline + egress-database + egress-external | CNPG + optional fetch |
| `sparkyfitness` | baseline + egress-database + egress-external | CNPG + OIDC |
| `tandoor` | baseline + egress-database + egress-mail | CNPG + SMTP |
| `outline` | baseline + egress-database + egress-external + egress-mail | CNPG + OIDC + SMTP |
| `teslamate` | baseline + egress-database + egress-external | CNPG + Tesla API |

## Phase 4 (issue #739 — remaining app NS with bespoke egress, DONE)

App NS whose traffic needs more than the stock components — each got a
bespoke egress policy:

| Namespace | Bespoke | Components |
|-----------|---------|------------|
| `homepage` | egress → LAN `192.168.10.0/24` + pod CIDR `10.244.0.0/16` (status widgets) | baseline + egress-external |
| `kite` | egress → `monitoring` vmselect `:8481` | baseline + egress-external |
| `renovate` | egress → `forgejo` `:3000` | baseline + egress-external |
| `spectrumknx` | egress → KNX gateway `192.168.10.20:3671` (TCP+UDP) | baseline |
| `nextcloud-exapps` | egress → `nextcloud` `:8780/:8782` (AppAPI harp) | baseline + egress-external |
| `mcp-system` | — | baseline + egress-apiserver + egress-external |
| `external-dns` | — | baseline + egress-external + egress-apiserver |
| `ai-ops` (n8n) | — | baseline + egress-external + egress-apiserver |

## Phase 5 (issue #772 — infra/operator NS, DONE)

Seven operator namespaces rolled out with individually-mapped bespoke egress/
ingress (see issue #772). Validated per-namespace against the live cluster:
provision a volume, issue a cert, run a backup — no breakage.

| Namespace | Components | Bespoke | Why / verification |
|-----------|------------|---------|--------------------|
| `cert-manager` | baseline + egress-external + egress-apiserver | `allow-ingress-webhook` | ACME DNS-01 via Hetzner (egress-external :443); controller/cainjector/webhook watch API (egress-apiserver); admission webhook ingress from API-server VIP `192.168.10.245` + CP `192.168.10.41-43` on 9443/443 (mirrors cnpg-system). **Verified:** test `Certificate` admitted + Hetzner webhook created the DNS-01 TXT record. |
| `democratic-csi` | baseline + egress-apiserver | `allow-egress-truenas` | TrueNAS API `192.168.10.94:443` (provision/attach + health pings) + iSCSI target `192.168.10.94:3260` (volume attach). **Verified:** test RWO PVC bound + iSCSI volume mounted in a pod. |
| `local-path-storage` | baseline + egress-apiserver | — | provisioner watches PVCs/nodes via API. **Verified:** test PVC bound + pod Running. |
| `velero` | baseline + egress-apiserver | `allow-egress-s3-garage` | Garage S3 `192.168.10.94:30188` (`:30190` too, mirrors `nextcloud`). **Verified:** `kopia-maintain` jobs complete; test `Backup` reaches S3. |
| `backup-offsite` | baseline + egress-database | `allow-egress-storagebox` | Hetzner Storage Box over SFTP/SSH — pinned to resolved A `62.238.65.94` + AAAA `2a01:4f9:bacc:3:300::25e` on 22/23 (not opened to `0.0.0.0/0`). `pg_dump` → CNPG (egress-database). NFS source mounts are node-side (kubelet), not pod egress. **Verified:** offsite CronJobs complete. |
| `reflector-system` | baseline + egress-apiserver | — | watches secrets/CM across NS, replicates the cert-manager wildcard cert. **Verified:** pod Running, replication intact. |

### hostNetwork namespaces — NP-inert, explicitly excluded

`ingress-nginx`, `netbird`, `watchyourlan`, `system-upgrade` (plan jobs) all use
`hostNetwork` (or privileged host mounts). Cilium/standard NetworkPolicies do
**not** govern host-network traffic, so a default-deny there is inert and adds
no protection. They are intentionally **not** added to the parent
`network-policies/kustomization.yaml` — their isolation relies on host firewall
/ Talos machinery, out of scope of this rollout. Revisit only if the CNI gains
host-network policy support.

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
      # - ../egress-database   # if it uses the central CNPG tier (postgres:5432)
      # - ../egress-apiserver  # if it runs a controller/operator watching the API
      # - ../egress-mail       # if it sends/receives mail (465/587/993)
    # resources:              # bespoke egress/ingress not covered by a component
    #   - allow-egress-<thing>.yaml
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
