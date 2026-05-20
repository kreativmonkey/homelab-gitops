# Applications: Enable, Disable, and Configure

This document explains how to manage the Application catalog of the homelab
cluster from Git. **No `kubectl apply` — every change goes through a PR,
Flux reconciles it.**

## TL;DR for humans

```text
┌───────────────────────────────────────────────────────────────────┐
│  Want to …                          │  Edit this file              │
├───────────────────────────────────────────────────────────────────┤
│  Enable / disable an app            │  apps/overlays/main/         │
│                                     │    kustomization.yaml        │
│  Change an app's hostname           │  apps/overlays/main/         │
│                                     │    cluster-config.yaml       │
│  Change the apex / cluster domain   │  apps/overlays/main/         │
│                                     │    cluster-config.yaml       │
│  Add a brand-new app                │  apps/base/<name>/           │
│                                     │  + register in overlay       │
└───────────────────────────────────────────────────────────────────┘
```

After every change:

```bash
nix develop
just validate       # yamllint + kustomize + kubeconform + helm template
git commit -am "…"
git push
# Flux reconciles automatically (1h interval, or trigger:)
flux reconcile kustomization apps --with-source
```

## 1. The catalog file (`apps/overlays/main/kustomization.yaml`)

This is the **single switchboard** that decides which applications run in
the cluster.

```yaml
resources:
  - ../../base/audiobookshelf        # enabled
  - ../../base/jellyfin              # enabled
  # - ../../base/uptime-kuma         # disabled (line commented)
```

- **Enable an app**: remove the leading `#` of its line.
- **Disable an app**: prefix the line with `#`.

Flux runs `prune: true` on the apps Kustomization, so disabling an app
removes its workloads from the cluster on the next reconcile. PersistentVolumes
with `Retain` reclaim policy stay around to protect data; remove them
manually if you want to free storage.

### Marker `# wip:` — what it means

Some apps are listed but commented because they have only a namespace +
ingress placeholder and no Deployment / HelmRelease yet. They are documented
here so it is obvious what is **planned** but not deployed:

| App                | Status | Reason                                    |
|--------------------|--------|-------------------------------------------|
| tandoor            | wip    | ingress only, missing HelmRelease         |
| netbird            | on     | DaemonSet (hostNetwork), routing to cluster |
| backrest           | wip    | ingress only, missing HelmRelease         |
| searxng            | on     | Deployment + ingress at search.f4mily.net |
| uptime-kuma        | wip    | ingress only, missing Deployment          |
| unifi-controller   | wip    | ingress only, missing HelmRelease         |
| nextcloud          | on     | HelmRelease + CNPG + NFS at cluster domain  |
| linkwarden         | wip    | ingress only, missing HelmRelease         |
| speedtest-tracker  | wip    | ingress only, missing Deployment          |
| watchyourlan       | wip    | ingress only, missing Deployment          |
| teslamate          | on     | Deployment, Mosquitto, CNPG, teslamate.cluster.f4mily.net |
| goloom             | on     | Deployment, CNPG PostgreSQL, goloom.cluster.f4mily.net |
| pcm                | wip    | ingress only, missing HelmRelease         |

## 2. The config file (`apps/overlays/main/cluster-config.yaml`)

All cluster-wide knobs (domains, TLS, per-app hostnames) live in one
`ConfigMap` annotated with `config.kubernetes.io/local-config: "true"`
— meaning Kustomize uses it during build but **never emits it to the
cluster** (no resource noise).

```yaml
data:
  publicDomain: f4mily.net                 # *.f4mily.net wildcard
  clusterDomain: cluster.f4mily.net        # *.cluster.f4mily.net wildcard
  clusterIssuer: letsencrypt-production
  publicTlsSecret: wildcard-f4mily-net-tls
  clusterTlsSecret: wildcard-cluster-f4mily-net-tls
  ingressClassName: nginx

  host_audiobookshelf: audible.f4mily.net
  host_homepage: home.f4mily.net
  ...
```

Kustomize **replacements** in `kustomization.yaml` push the `host_<app>`
values into each Ingress' `spec.rules[0].host`, `spec.tls[0].hosts[0]`
and (where applicable) into HelmRelease values.

### Change an app's hostname

1. Edit `host_<app>` in `cluster-config.yaml`.
2. Verify with `kustomize build apps/overlays/main | grep <hostname>`.
3. Commit; Flux re-renders the ingress.

### Change the base domain (e.g. f4mily.net → example.org)

1. Update `publicDomain` and `clusterDomain` (informational).
2. Update **every** `host_*` value (only the domain portion).
3. Update the wildcard certificates under
   `infrastructure/base/network/certificates/` (`secretName` & `dnsNames`).
4. Update `publicTlsSecret` / `clusterTlsSecret` if you renamed the
   certificate secrets.
5. Update the cert-manager ClusterIssuer `solvers[].dns01.cnameStrategy`
   if needed (`infrastructure/base/network/cert-manager-issuer/clusterissuer.yaml`).
6. `just validate && git commit && git push`.

A find-replace helper (preview only):

```bash
rg "f4mily.net" apps/overlays/main/cluster-config.yaml
```

## 3. Adding a new application

Bake a new app in 5 steps:

```bash
APP=mynewapp; HOST=mynewapp.f4mily.net

# 1. Scaffold
mkdir -p apps/base/$APP
cat >apps/base/$APP/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
  - ingress.yaml
EOF

# 2. Manifests — copy patterns from apps/base/homepage/ (Deployment +
#    Service + Ingress) or apps/base/paperless-ngx/ (HelmRelease).

# 3. Add host to cluster-config.yaml
#       host_mynewapp: mynewapp.f4mily.net

# 4. Register replacement in kustomization.yaml
#       - source: …data.host_mynewapp
#         targets:
#           - select: {kind: Ingress, name: mynewapp}
#             fieldPaths: [spec.rules.0.host, spec.tls.0.hosts.0]

# 5. Enable in catalog
#       resources:
#         - ../../base/mynewapp
```

Then `just validate` and commit.

## 4. Storage strategy reminder

- `longhorn` / `longhorn-1` — RWO block storage for databases, configs,
  small state. `longhorn-1` is the cluster default (single replica).
- `nfs-media-static` — RWX network storage backed by TrueNAS at
  192.168.10.94. **Manually-defined PVs** in
  `infrastructure/base/storage/pv-nfs.yaml` with a `claimRef` to the
  intended app namespace.

When migrating an app from Longhorn → NFS, you must first delete the
existing `Bound` PVC. PVC specs (storageClassName, accessModes,
volumeName) are **immutable**. See `docs/migrations/nfs-migration.md`.

## 5. Reconciliation cheat sheet

```bash
# All Flux kustomizations / helmreleases
flux get kustomizations -A
flux get helmreleases -A

# Force a refresh after a Git push
flux reconcile source git flux-system
flux reconcile kustomization apps --with-source

# Suspend / resume an app while debugging
flux suspend  helmrelease -n immich immich
flux resume   helmrelease -n immich immich

# Detailed events for a stuck release
flux logs --kind=HelmRelease --name=immich --namespace=immich --follow
```
