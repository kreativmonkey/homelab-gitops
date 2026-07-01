<div align="center">

# 🏠 Homelab GitOps

**The entire Kubernetes cluster state as code — rolled out purely via Git.**

Single Source of Truth for my self-hosted homelab on **Talos Linux**,
continuously reconciled by **FluxCD**. GitHub is leading; Forgejo is an
in-cluster mirror.

<!-- Status & Tooling -->
[![CI](https://img.shields.io/github/actions/workflow/status/kreativmonkey/homelab-gitops/pr-validation.yaml?branch=main&style=for-the-badge&label=CI&logo=github&logoColor=white)](https://github.com/kreativmonkey/homelab-gitops/actions/workflows/pr-validation.yaml)
[![Renovate](https://img.shields.io/badge/Renovate-enabled-1A1F6C?style=for-the-badge&logo=renovatebot&logoColor=white)](https://renovatebot.com)
[![SOPS](https://img.shields.io/badge/Secrets-SOPS%20%2B%20age-1E5EFF?style=for-the-badge&logo=gnuprivacyguard&logoColor=white)](https://github.com/getsops/sops)
[![Last commit](https://img.shields.io/github/last-commit/kreativmonkey/homelab-gitops/main?style=for-the-badge&logo=git&logoColor=white)](https://github.com/kreativmonkey/homelab-gitops/commits/main)

<!-- Stack -->
[![Talos Linux](https://img.shields.io/badge/Talos_Linux-FF7300?style=for-the-badge&logo=talos&logoColor=white)](https://www.talos.dev/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![FluxCD](https://img.shields.io/badge/GitOps-FluxCD-5468FF?style=for-the-badge&logo=flux&logoColor=white)](https://fluxcd.io/)
[![Helm](https://img.shields.io/badge/Helm-0F1689?style=for-the-badge&logo=helm&logoColor=white)](https://helm.sh/)
[![Cilium](https://img.shields.io/badge/CNI-Cilium-F8C517?style=for-the-badge&logo=cilium&logoColor=black)](https://cilium.io/)
[![NGINX Ingress](https://img.shields.io/badge/Ingress-NGINX-009639?style=for-the-badge&logo=nginx&logoColor=white)](https://kubernetes.github.io/ingress-nginx/)
[![CloudNativePG](https://img.shields.io/badge/Postgres-CloudNativePG-336791?style=for-the-badge&logo=postgresql&logoColor=white)](https://cloudnative-pg.io/)
[![cert-manager](https://img.shields.io/badge/TLS-cert--manager-2E77BC?style=for-the-badge&logo=letsencrypt&logoColor=white)](https://cert-manager.io/)

</div>

> **New here?** Start with [`docs/cluster-access.md`](./docs/cluster-access.md)
> to get a kubeconfig, then [`docs/applications.md`](./docs/applications.md)
> to learn how to enable / disable apps and configure their hostnames.

---

## How it works

```text
git push ──▶ GitHub (main) ──▶ FluxCD ──▶ Kustomize / Helm ──▶ Talos Cluster
                                  │
                                  └─▶ SOPS + age decrypt secrets in-cluster
```

Everything is declarative: the cluster's desired state lives in this repo,
Flux reconciles it every hour (or on demand). Changes land via **PRs to
`main`** — never `kubectl edit`.

---

## Infrastructure Overview

| Component | Technology | Role |
| :--- | :--- | :--- |
| **VCS / Mirror** | GitHub (Primary) + Forgejo (Mirror) | GitHub is leading; Forgejo is in-cluster mirror. |
| **Secrets** | [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) | Encrypted GitOps secrets (in-repo encryption) |
| **OS & K8s** | [Talos Linux](https://www.talos.dev/) | Immutable, RAM-based, API-managed OS |
| **GitOps** | [FluxCD](https://fluxcd.io/) | Reconciles Git state to cluster state |
| **CNI** | [Cilium](https://cilium.io/) | eBPF-based cluster networking |
| **Storage (DB)** | node-local `local-path` | Per-node disks for CloudNativePG (off the iSCSI SPOF; CNPG replicates at the DB layer) |
| **Storage (Fast)** | TrueNAS iSCSI (democratic-csi) | RWO block storage for app state/config |
| **Storage (Mass)** | NFS (External NAS) | Persistent storage for media and archives |
| **Networking** | NGINX Ingress / [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) | Ingress control and Cloudflare DNS sync |
| **Security** | [cert-manager](https://github.com/cert-manager/cert-manager) | Automated TLS via Let's Encrypt (DNS-01) |
| **Observability** | [VictoriaMetrics](https://victoriametrics.com/) Stack | High-performance monitoring and alerting |
| **Automation** | [Renovate Bot](https://github.com/mend/renovate-ce-ee/tree/main) | Automated dependency and image updates |
| **Data Policy** | [Velero](https://velero.io/) | Volume snapshots and offsite backups |

---

## Applications & Status

This cluster runs a variety of self-hosted applications. Uptime is monitored
via [Gatus](https://status.cluster.f4mily.net).

| Application | Category | Uptime |
| :--- | :--- | :--- |
| [**authentik**](https://goauthentik.io/) | Security | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/core_authentik/uptimes/30d/badge.svg) |
| [**forgejo**](https://forgejo.org/) | Git Mirror | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/core_git/uptimes/30d/badge.svg) |
| [**nextcloud**](https://nextcloud.com/) | Productivity | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/core_nextcloud/uptimes/30d/badge.svg) |
| [**homepage**](https://gethomepage.dev/) | Dashboard | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/core_homepage/uptimes/30d/badge.svg) |
| [**searxng**](https://docs.searxng.org/) | Search | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/core_searxng/uptimes/30d/badge.svg) |
| [**audiobookshelf**](https://www.audiobookshelf.org/) | Media | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/media_audiobookshelf/uptimes/30d/badge.svg) |
| [**immich**](https://immich.app/) | Media | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/media_immich/uptimes/30d/badge.svg) |
| [**jellyfin**](https://jellyfin.org/) | Media | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/media_jellyfin/uptimes/30d/badge.svg) |
| [**kavita**](https://www.kavitareader.com/) | Media | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/media_kavita/uptimes/30d/badge.svg) |
| [**paperless-ngx**](https://docs.paperless-ngx.com/) | Documents | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/documents_paperless/uptimes/30d/badge.svg) |
| [**readeck**](https://readeck.org/) | Documents | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/documents_readeck/uptimes/30d/badge.svg) |
| [**Stirling-PDF**](https://github.com/Stirling-Tools/Stirling-PDF) | Documents | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/documents_sterling-pdf/uptimes/30d/badge.svg) |
| [**Outline**](https://www.getoutline.com/) | Knowledge Base | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/application_outline/uptimes/30d/badge.svg) |
| [**linkding**](https://github.com/sissis-m/linkding) | Bookmarks | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/application_linkding/uptimes/30d/badge.svg) |
| [**tandoor**](https://tandoor.dev/) | Recipes | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/application_tandoor/uptimes/30d/badge.svg) |
| [**SparkyFitness**](https://github.com/codewithcj/SparkyFitness) | Fitness | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/application_fitness/uptimes/30d/badge.svg) |
| [**n8n**](https://n8n.io/) | Automation | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/automation_n8n/uptimes/30d/badge.svg) |
| [**goloom**](https://github.com/Goloom-App/goloom) | Automation | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/automation_goloom/uptimes/30d/badge.svg) |
| [**SpectrumKNX**](https://github.com/martinhoefling/SpectrumKNX) | Smart Home | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/automation_spectrumknx/uptimes/30d/badge.svg) |
| [**teslamate**](https://github.com/adriankumpf/teslamate) | Car Tracking | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/observability_teslamate/uptimes/30d/badge.svg) |
| [**dawarich**](https://dawarich.app/) | Location Tracking | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/application_dawarich/uptimes/30d/badge.svg) |
| [**watchyourlan**](https://github.com/aceberg/WatchYourLAN) | Network | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/observability_watchyourlan/uptimes/30d/badge.svg) |
| [**homer**](https://github.com/bastienwirtz/homer) | Dashboard | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/observability_homer/uptimes/30d/badge.svg) |
| [**grafana**](https://grafana.com/) | Observability | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/observability_grafana/uptimes/30d/badge.svg) |

---

## Infrastructure Principles

### 1. Dependency Management
Standard tools (Helm charts, Docker images) are managed by Renovate. GitHub is
the primary source of truth.

### 2. Networking
Talos nodes run Cilium CNI. Ingress is handled by the NGINX Ingress Controller.
SSL certificates are automated via cert-manager (Let's Encrypt).

### 3. Persistence Strategy
Storage is matched to each workload's **own** replication model — not a
one-size-fits-all default.

* **Databases — node-local `local-path` (NOT iSCSI):** CloudNativePG (PostgreSQL)
  clusters run on per-node `local-path` storage. CNPG replicates at the database
  layer (3 instances + continuous S3/barman backups), so node-local disks are
  both faster *and* keep the shared-NAS **single point of failure out of the
  database path**. This is the CNPG-recommended pattern; the previous setup ran
  every DB on one TrueNAS iSCSI target, which repeatedly cascaded (a single iSCSI
  blip → WAL corruption → cluster-wide CNPG outage). Provisioner:
  `infrastructure/base/storage/local-path-provisioner/`; class `local-path`
  (non-default).
  > ⚠️ **Legacy mount path:** the backing data disk is still mounted at
  > `/var/lib/longhorn` (a misleading leftover — Longhorn was never deployed).
  > Grep **`LEGACY-MOUNT-PATH`** for the pending rename to
  > `/var/mnt/local-storage` (already in the IaC, awaiting a Talos `tofu apply`).
* **App RWO volumes (iSCSI):** Application config/data volumes that have **no
  app-level replication** use Democratic CSI on TrueNAS (`truenas-iscsi`, the
  default class), backed up via Velero. (Such volumes are better served by
  replicated storage — Longhorn — than node-pinned `local-path`; a future
  improvement.)
* **Mass Storage (NFS):** Large media files (Photos, Videos, Books) and bulk
  document storage.

**Migrating a CNPG cluster's storage** — a `storageClass` change applies to
**new** instances only. Roll existing instances one at a time
(`kubectl -n cnpg-system delete pvc <inst> --wait=false && kubectl -n cnpg-system delete pod <inst>`);
CNPG re-bootstraps each via `pg_basebackup`. Wait for `N/N` healthy between
steps; do the **primary last** (brief failover).

### 4. GitOps (FluxCD)
Flux reconciles the cluster state against the GitHub repository. Changes are
applied via PRs to the `main` branch.

---

## Repository Structure

```text
homelab-gitops/
├── clusters/                # Flux entry points
│   └── main/                # Production cluster config
├── infrastructure/          # Cluster-wide components
│   ├── base/                # Shared sources
│   │   ├── storage/         # local-path (CNPG) + iSCSI (democratic-csi) + NFS PVs
│   │   ├── database/        # CloudNativePG operator
│   │   └── ...
│   └── overlays/main/       # Cluster patches & secrets
├── apps/                    # Business applications
│   ├── base/                # Generic HelmReleases & manifests
│   └── overlays/main/       # Environment-specific overrides
├── docs/                    # Architecture, runbooks, migrations
└── scripts/                 # Maintenance and CI helpers
```

---

## Development Environment (Nix Shell)

```bash
# Dev shell with just + stack tooling (kubectl, flux, kustomize, sops, ...)
nix develop

# List available tasks
just
```

### Local validation

```bash
just validate   # lint + kustomize build + kubeconform + helm template
```

Run this before every push — it mirrors the **PR Validation** CI check.

---

## Secrets (SOPS + age)

Secrets are encrypted **in-repo** with SOPS and an age key; Flux decrypts them
in-cluster. Never commit plaintext secrets.

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

sops path/to/secret.sops.yaml          # edit an encrypted file
sops --encrypt --in-place secret.yaml  # encrypt a new secret
```

---

## Bootstrap & Recovery

The cluster is bootstrapped from the sibling
[`homelab-infrastructure`](../homelab-infrastructure) repository via OpenTofu
(see `homelab-infrastructure/talos/`). The Terraform module `flux.tf` performs
the Flux bootstrap and seeds the SOPS age secret. After Tofu apply, this repo is
the only thing Flux ever needs.

### Day-1: bootstrap a fresh cluster

```bash
cd ../homelab-infrastructure
nix develop .#talos
cd talos
tofu init && tofu apply        # Creates VMs, applies Talos config, bootstraps Flux
kubectl get nodes              # 3 control planes
flux get kustomizations -A     # All green
```

### Day-2: change something in this repo

```bash
nix develop                    # homelab-gitops dev-shell
just validate                  # lint + kustomize + kubeconform + helm template
git commit -am "feat: …" && git push
flux reconcile kustomization apps --with-source   # optional, otherwise 1h interval
```

### Disaster recovery

Full runbook: [`docs/disaster-recovery/README.md`](./docs/disaster-recovery/README.md).
CNPG S3 restore: [`docs/disaster-recovery/cnpg-s3-dr.md`](./docs/disaster-recovery/cnpg-s3-dr.md).
Short version: the central PostgreSQL cluster is continuously backed up to S3
(Garage) via Barman. The `disaster-recovery` overlay rehydrates the cluster from
S3 on a fresh deploy.

---

## Governance

1. **GitHub is leading:** Always push to GitHub. Forgejo is a local mirror.
2. **Surgical changes:** Use targeted Kustomize patches instead of duplicating base manifests.
3. **Persistence strategy:** Match storage to each workload's replication model (see above).
4. **Security:** Secrets are encrypted with SOPS (age). Never commit plaintext secrets.
5. **Automated updates:** Let Renovate handle version bumps; manual overrides only when necessary.

---

## Further Documentation

- [`docs/cluster-access.md`](./docs/cluster-access.md) — get a kubeconfig
- [`docs/applications.md`](./docs/applications.md) — enable/disable apps & hostnames
- [`docs/disaster-recovery/README.md`](./docs/disaster-recovery/README.md) — recovery runbook
