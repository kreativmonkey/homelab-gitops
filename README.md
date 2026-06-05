# 📁 Homelab GitOps Repository

This repository is the **Single Source of Truth** for my Kubernetes homelab. It leverages a declarative approach to manage infrastructure on **Talos Linux** using **FluxCD** for continuous delivery. GitHub is the primary source; Forgejo is an in-cluster mirror.

> **New here?** Start with [`docs/cluster-access.md`](./docs/cluster-access.md)
> to get a kubeconfig, then [`docs/applications.md`](./docs/applications.md)
> to learn how to enable / disable apps and configure their hostnames.

## 🏗 Infrastructure Overview

| Component | Technology | Role |
| :--- | :--- | :--- |
| **VCS / Mirror** | GitHub (Primary) + Forgejo (Mirror) | GitHub is leading; Forgejo is in-cluster mirror. |
| **Secrets** | [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) | Encrypted GitOps secrets (In-repo encryption) |
| **OS & K8s** | [Talos Linux](https://www.talos.dev/) | Immutable, RAM-based, API-managed OS |
| **GitOps** | [FluxCD](https://fluxcd.io/) | Reconciles Git state to Cluster state |
| **Storage (Fast)** | TrueNAS iSCSI (democratic-csi) | RWO block storage for DBs/State |
| **Storage (Mass)** | NFS (External NAS) | Persistent storage for media and archives |
| **Networking** | Nginx Ingress / [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) | Ingress control and Cloudflare DNS sync |
| **Security** | [cert-manager](https://github.com/cert-manager/cert-manager) | Automated TLS via Let's Encrypt (DNS-01) |
| **Observability**| [VictoriaMetrics](https://victoriametrics.com/) Stack | High-performance monitoring and alerting |
| **Automation** | [Renovate Bot](https://github.com/mend/renovate-ce-ee/tree/main) | Automated dependency and image updates |
| **Data Policy** | [Velero](https://velero.io/) | Volume snapshots and offsite backups |

## 🚀 Applications & Status

This cluster runs a variety of self-hosted applications. Uptime is monitored via [Gatus](https://status.cluster.f4mily.net).

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
| **goloom** | Automation | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/automation_goloom/uptimes/30d/badge.svg) |
| [**teslamate**](https://github.com/adriankumpf/teslamate) | Car Tracking | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/observability_teslamate/uptimes/30d/badge.svg) |
| [**watchyourlan**](https://github.com/aceberg/WatchYourLAN) | Network | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/observability_watchyourlan/uptimes/30d/badge.svg) |
| [**homer**](https://github.com/bastienwirtz/homer) | Dashboard | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/observability_homer/uptimes/30d/badge.svg) |
| [**grafana**](https://grafana.com/) | Observability | ![Uptime](https://status.cluster.f4mily.net/api/v1/endpoints/observability_grafana/uptimes/30d/badge.svg) |

## 🏗 Infrastructure Principles

### 1. Dependency Management
Standard tools (Helm charts, Docker images) are managed by Renovate. GitHub is the primary source of truth.

### 2. Networking
Talos nodes run Cilium CNI. Ingress is handled by the NGINX Ingress Controller. SSL certificates are automated via cert-manager (Let's Encrypt).

### 3. Persistence Strategy
* **High Performance (iSCSI):** Used for databases (PostgreSQL, Redis) and application configs via Democratic CSI on TrueNAS. These provide high IOPS and are backed up via Velero.
* **Mass Storage (NFS):** Used for large media files (Photos, Videos, Books) and large-scale document storage.

### 4. GitOps (FluxCD)
Flux reconciles the cluster state against the GitHub repository. Changes are applied via PRs to the `main` branch.

---

## 🛠 Directory Structure

```text
/home/sebastian/git/git.f4mily.net/homelab/gitops-homelab/
├── clusters/                # Flux entry points
│   └── main/                # Production cluster config
├── infrastructure/          # Cluster-wide components
│   ├── base/                # Shared sources
│   │   ├── storage/         # iSCSI (democratic-csi) + NFS PVs
│   │   ├── database/        # CloudNativePG operator
│   │   └── ...
│   └── overlays/main/       # Cluster patches & secrets
├── apps/                    # Business applications
│   ├── base/                # Generic HelmReleases & manifests
│   └── overlays/main/       # Environment-specific overrides
├── docs/                    # Architecture, Runbooks, Migrations
└── scripts/                 # Maintenance and CI helpers
```

## 📜 Governance
1.  **GitHub is Leading:** Always push to GitHub. Forgejo is a local mirror.
2.  **Surgical Changes:** Use targeted Kustomize patches instead of duplicating base manifests.
3.  **Persistence Strategy:** Prefer `truenas-iscsi` for anything needing high IOPS.
4.  **Security:** Secrets are encrypted with SOPS (Age). Never commit plain text secrets.
5.  **Automated Updates:** Let Renovate handle version bumps; manual overrides only when necessary.

---

## 🚀 Getting Started

1.  **Clone the Repo:** `git clone git@github.com:kreativmonkey/homelab-gitops.git`
2.  **Initialize Environment:** Use the provided Nix flake: `nix develop`.
3.  **Secrets:** Ensure you have access to the cluster's `age` private key and set `SOPS_AGE_KEY_FILE`.
4.  **Validate:** Run `just validate` to check manifests before pushing.

---

## 🚀 Bootstrap & Recovery

The cluster is bootstrapped from the sibling
[`homelab-infrastructure`](../homelab-infrastructure) repository via
OpenTofu (see `homelab-infrastructure/talos/`). The Terraform module
`flux.tf` performs the Flux bootstrap and seeds the SOPS age secret.
After Tofu apply, this repo is the only thing Flux ever needs.

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
nix develop                    # gitops-homelab dev-shell
just validate                  # lint + kustomize + kubeconform + helm template
git commit -am "feat: …" && git push
flux reconcile kustomization apps --with-source   # optional, otherwise 1h interval
```

### Disaster recovery

Full runbook: [`docs/disaster-recovery/README.md`](./docs/disaster-recovery/README.md).  
CNPG S3 restore: [`docs/disaster-recovery/cnpg-s3-dr.md`](./docs/disaster-recovery/cnpg-s3-dr.md).
Short version: the central PostgreSQL cluster is continuously backed up
to S3 (Garage) via Barman. The `disaster-recovery` overlay rehydrates
the cluster from S3 on a fresh deploy.
