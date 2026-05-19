# 📁 Homelab GitOps Repository

This repository is the **Single Source of Truth** for my Kubernetes homelab. It leverages a declarative approach to manage infrastructure on **Talos Linux** using **FluxCD** for continuous delivery.

> **New here?** Start with [`docs/cluster-access.md`](./docs/cluster-access.md)
> to get a kubeconfig, then [`docs/applications.md`](./docs/applications.md)
> to learn how to enable / disable apps and configure their hostnames.

## 🏗 Infrastructure Overview

| Component | Technology | Role |
| :--- | :--- | :--- |
| **Secrets** | [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) | Encrypted GitOps secrets (In-repo encryption) |
| **OS & K8s** | [Talos Linux](https://www.talos.dev/) | Immutable, RAM-based, API-managed OS |
| **GitOps** | [FluxCD](https://fluxcd.io/) | Reconciles Git state to Cluster state |
| **Storage (Fast)** | [Longhorn](https://longhorn.io/) | Distributed Block Storage for DBs/State |
| **Storage (Mass)** | NFS (External NAS) | Persistent storage for media and archives |
| **Networking** | Nginx Ingress / [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) | Ingress control and Cloudflare DNS sync |
| **Security** | [cert-manager](https://github.com/cert-manager/cert-manager) | Automated TLS via Let's Encrypt (DNS-01) |
| **Observability**| [VictoriaMetrics](https://victoriametrics.com/) Stack | High-performance monitoring and alerting |
| **Automation** | [Renovate Bot](https://github.com/mend/renovate-ce-ee/tree/main) | Automated dependency and image updates |
| **Data Policy** | [Velero](https://velero.io/) | Volume snapshots and offsite backups |

## 🏗 Infrastructure Principles

### 1. Dependency Management
To ensure a stable boot sequence, the cluster follows a strict hierarchy:
* **Infrastructure First:** Storage, Networking, and Certs are reconciled before any application.
* **Health Checks:** Flux monitors the `ready` state of infrastructure before proceeding to the `apps` layer.

### 2. Hybrid Storage Strategy
We distinguish between two types of persistence:
* **High Performance (Longhorn):** Used for databases (PostgreSQL, Redis) and application configs. These provide high IOPS and automated volume replication.
* **Mass Storage (NFS):** Used for large media archives (e.g., Photos, Videos). Managed via static `PersistentVolumes` pointing to the external NAS.

### 3. Networking & Security
* **Ingress:** Automated through Nginx.
* **TLS:** Issued via `cert-manager` using **DNS-01 challenges** (supporting wildcard certs and internal-only domains).
* **Workload Security:** All apps follow the principle of least privilege (non-root UIDs, no privilege escalation).

## 📂 Repository Structure

The repository follows a strict Kustomize **base/overlay** structure. The
**overlay** is the *human switchboard* — it decides which apps are
deployed and what hostnames/TLS they use. The **base** holds reusable,
opinionated manifests per app.

```bash
.
├── clusters/
│   └── main/                       # FluxCD entry point for the homelab cluster
│       ├── flux-system/            # Bootstrap (Flux components + GitRepository)
│       ├── infrastructure.yaml     # Kustomization → infrastructure/ (priority 1)
│       └── apps.yaml               # Kustomization → apps/ (depends on infra)
│
├── infrastructure/                 # Core cluster components
│   ├── base/
│   │   ├── sources/                # HelmRepositories, IngressClass, namespaces
│   │   ├── storage/                # Longhorn HR + static NFS PVs + storageclasses
│   │   ├── network/
│   │   │   ├── cert-manager/       # cert-manager HelmRelease
│   │   │   ├── cert-manager-issuer/# Let's Encrypt ClusterIssuer (Hetzner DNS-01)
│   │   │   ├── certificates/       # Wildcard Certificates (*.f4mily.net, *.cluster.f4mily.net)
│   │   │   ├── external-dns/       # ExternalDNS HelmRelease
│   │   │   └── ingress/            # nginx-ingress HelmRelease
│   │   ├── database/cnpg/          # CloudNativePG operator
│   │   ├── backup/                 # Velero HelmRelease
│   │   └── backup-schedules/       # Velero Schedules (daily / weekly)
│   └── overlays/main/              # Cluster-specific patches
│       ├── database-clusters/      # Central PostgreSQL cluster + barman S3
│       └── pgadmin/                # pgAdmin UI for the central cluster
│
└── apps/
    ├── base/                       # One self-contained kustomize base per app
    │   ├── audiobookshelf/         #   namespace, deployment, ingress, …
    │   ├── homepage/
    │   ├── homer/
    │   ├── immich/                 # HelmRelease + ingress + NFS PVCs
    │   ├── paperless-ngx/          # HelmRelease + NFS PVCs
    │   ├── monitoring/vm-k8s-stack # VictoriaMetrics + Grafana
    │   └── …                       # ~20 apps total
    └── overlays/main/              # ◀ THE SWITCHBOARD
        ├── kustomization.yaml      #   enabled/disabled apps + replacements
        ├── cluster-config.yaml     #   ConfigMap: domains, TLS, per-app hosts
        ├── databases/              #   CNPG `Database` CRs (per-app schemas)
        └── db-secrets/             #   SOPS-encrypted DB user passwords
```

See [`docs/applications.md`](./docs/applications.md) for the day-to-day
workflow (enable / disable apps, change hostnames, add a new app) and
[`docs/cluster-access.md`](./docs/cluster-access.md) for how to talk to
the cluster (kubeconfig, talosctl, flux CLI).

## 🛡 Design Principles

1.  **Immutability:** No manual `kubectl` changes. If it's not in Git, it doesn't exist.
2.  **Security First:** Workloads run as non-root (UID 1000/1001) with `allowPrivilegeEscalation: false`.
3.  **Persistence Strategy:** * **Longhorn:** Used for high-IOPS workloads (PostgreSQL, Redis, Configs).
    * **NFS:** Used for bulk data (Media, Backups).
4.  **Observability:** Every service must export metrics via a `ServiceMonitor`.
5.  **Automated Maintenance:** Renovate handles version bumps; Talos handles node-level immutability.

---

## 🔐 Secret Management

This repository uses **SOPS** with the **age** encryption tool. Secrets are encrypted locally before being committed to Git and are decrypted by the Flux controller inside the cluster.

### Key Management
* **Public Key:** `age1...` (Stored in `.sops.yaml` for encryption).
* **Private Key:** Stored in the cluster as a Kubernetes Secret named `sops-age` in the `flux-system` namespace.

### Workflow: Creating/Editing Secrets

With `nix develop` (includes `just` and `sops`):

```bash
just sops-create my-secret flux-system . api-key=12345
just sops-edit infrastructure/base/sources/my-secret.secret.yaml
```

Manual equivalent: `kubectl create secret … --dry-run=client -o yaml` then `sops --encrypt --in-place`.

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

### Disaster recovery (Postgres only)

Documented in [`docs/disaster-recovery/cnpg-s3-dr.md`](./docs/disaster-recovery/cnpg-s3-dr.md).
Short version: the central PostgreSQL cluster is continuously backed up
to S3 (Garage) via Barman. The `disaster-recovery` overlay rehydrates
the cluster from S3 on a fresh deploy.
