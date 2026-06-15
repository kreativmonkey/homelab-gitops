# Purpose

Cluster-wide services: database operator, storage, networking/ingress, backup + disaster recovery, system upgrades, metrics/exporters, sources. `base/` holds generic manifests/HelmReleases; `overlays/main/` holds cluster patches; `overlays/disaster-recovery/` holds the DR overlay.

# Ownership

- Owns: CNPG operator, democratic-csi (TrueNAS iSCSI + NFS), Cilium/NGINX ingress, cert-manager, Flux sources, backup schedules, DR overlay, system-upgrade-controller, metrics-server, exporters, per-app CNPG `Cluster` manifests under `overlays/main/database-clusters/`.
- App workloads owned by [[apps]].
- Parent root AGENTS.md owns global rules + DOX rail.

# Local Contracts

- Single CNPG cluster operator in `base/database/cnpg/`. Per-app DB clusters live in `overlays/main/database-clusters/<app>/`.
- CNPG `barmanObjectStore` (S3-compatible) for base-backup + WAL archiving. S3 creds never plaintext — SealedSecrets/ExternalSecrets placeholders.
- DR overlay `overlays/disaster-recovery/` patches CNPG `Cluster` with `spec.bootstrap.recovery`. Restore flow: apply DR overlay → CNPG restores → Flux syncs apps.
- Storage: democratic-csi iSCSI for fast workloads (DBs), NFS for large media.
- Ingress: NGINX with `nginx.org/*` annotations + Cilium CNI.

# Work Guidance

- Prefer HelmReleases (Flux-managed) over static manifests for standard software.
- Comment complex patches inline in YAML.

# Verification

- `just fmt && just lint && just test` locally before PR.

# Child DOX Index

No child AGENTS.md. Subfolders inherit this contract.
