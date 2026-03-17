# 📁 Homelab GitOps Repository

This repository is the **Single Source of Truth** for my Kubernetes homelab. It leverages a declarative approach to manage infrastructure on **Talos Linux** using **FluxCD** for continuous delivery.

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

Understood. I have refined the repository structure to match your specific layout. This structure perfectly balances **dependency management** (Infrastructure must be ready before Apps start) and **logical separation** of concerns.

Here is the updated **README.md** in English, reflecting your exact directory schema.

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

The repository follows a Kustomize-friendly structure to separate base definitions from environment-specific overlays:

```bash
.
├── clusters/
│   └── homelab/                # FluxCD Entry Point
│       ├── flux-system/        # Auto-generated Flux configuration
│       ├── infrastructure.yaml # Kustomization: Syncs /infrastructure (Priority 1)
│       └── apps.yaml           # Kustomization: Syncs /apps (Depends on infrastructure)
│
├── infrastructure/             # Core Cluster Components
│   ├── sources/                # Central HelmRepositories (e.g., Jetstack, Nginx)
│   ├── storage/
│   │   ├── longhorn/           # CSI for distributed block storage
│   │   └── nfs-provisioner/    # Controller for dynamic NFS provisioning
│   ├── network/
│   │   ├── nginx-ingress/      # Ingress Controller
│   │   ├── cert-manager/       # TLS management & ClusterIssuers
│   │   └── external-dns/       # DNS automation for Pi-hole/Cloudflare
│   ├── observability/
│   │   └── victoriametrics/    # K8s Stack (Metrics, Grafana, Alertmanager)
│   └── backup/
│       └── velero/             # Disaster Recovery & Snapshots
│
└── apps/                       # User Applications & Services
    └── immich/                 # Example: Hybrid Storage Use-Case
        ├── namespace.yaml
        ├── storage/            # Longhorn (DB/Config) & Static NFS (Mass Data)
        ├── workloads/          # Deployments, StatefulSets & ConfigMaps
        ├── routing/            # Ingress & ExternalDNS configuration
        ├── observability/      # VictoriaMetrics ServiceMonitors
        └── kustomization.yaml  # Bundle for Flux reconciliation
```

## 🛡 Design Principles

1.  **Immutability:** No manual `kubectl` changes. If it's not in Git, it doesn't exist.
2.  **Security First:** Workloads run as non-root (UID 1000/1001) with `allowPrivilegeEscalation: false`.
3.  **Persistence Strategy:** * **Longhorn:** Used for high-IOPS workloads (PostgreSQL, Redis, Configs).
    * **NFS:** Used for bulk data (Media, Backups).
4.  **Observability:** Every service must export metrics via a `ServiceMonitor`.
5.  **Automated Maintenance:** Renovate handles version bumps; Talos handles node-level immutability.

Excellent addition. In a GitOps workflow, managing secrets securely is non-negotiable. Using **SOPS** (Secrets Operations) with **age** is the industry standard for FluxCD because it allows you to commit encrypted secrets directly to Git, which Flux can then decrypt on-the-fly using a private key stored in the cluster.

I will update the **Infrastructure Overview**, **Infrastructure Principles**, and provide a new **Secret Management** section for the README.

---

## 🔐 Secret Management

This repository uses **SOPS** with the **age** encryption tool. Secrets are encrypted locally before being committed to Git and are decrypted by the Flux controller inside the cluster.

### Key Management
* **Public Key:** `age1...` (Stored in `.sops.yaml` for encryption).
* **Private Key:** Stored in the cluster as a Kubernetes Secret named `sops-age` in the `flux-system` namespace.

### Workflow: Creating/Editing Secrets
1. **To create a new secret:**
   ```bash
   kubectl create secret generic my-secret --from-literal=api-key=12345 --dry-run=client -o yaml > secret.enc.yaml
   sops --encrypt --age $(cat ~/.config/sops/age/keys.txt | grep -oP "public key: \K(.*)") --encrypted-regex '^(data|stringData)$' --in-place secret.enc.yaml
   ```
2. **To edit an existing secret:**
   ```bash
   sops secret.enc.yaml
   ```

---

## 🚀 Bootstrap & Recovery

To bootstrap a new cluster on Talos:

1.  Apply the Talos machine configuration.
2.  Export your `GITHUB_TOKEN`.
3.  Run the Flux bootstrap command:
    ```bash
    flux bootstrap github \
      --owner=$GITHUB_USER \
      --repository=homelab-ops \
      --branch=main \
      --path=./clusters/prod \
      --personal
    ```
