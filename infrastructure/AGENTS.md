# Purpose

Cluster-wide services: database operator, storage, networking/ingress, backup + disaster recovery, system upgrades, metrics/exporters, sources. `base/` holds generic manifests/HelmReleases; `overlays/main/` holds cluster patches; `overlays/disaster-recovery/` holds the DR overlay.

# Ownership

- Owns: CNPG operator, democratic-csi (TrueNAS iSCSI + NFS), NGINX ingress, Cilium CNI (`base/network/cilium/`), NetworkPolicy tree (`base/network/network-policies/`), cert-manager, Flux sources, backup schedules, DR overlay, Omni cluster template sync (`base/omni-sync/`), metrics-server, exporters, per-app CNPG `Cluster` manifests under `overlays/main/database-clusters/`.
- App workloads owned by [[apps]].
- Parent root AGENTS.md owns global rules + DOX rail.

# Local Contracts

- OCI Helm charts: `OCIRepository` (tag = chart version) + HelmRelease `chartRef`, not `HelmRepository type: oci` (no status/Ready, maintenance mode). Set `layerSelector` helm chart content + `operation: copy`. Judge health via OCIRepository/HelmRelease Ready.
- Single CNPG cluster operator in `base/database/cnpg/`. Per-app DB clusters live in `overlays/main/database-clusters/<app>/`.
- CNPG `barmanObjectStore` (S3-compatible) for base-backup + WAL archiving. S3 creds never plaintext — SealedSecrets/ExternalSecrets placeholders.
- DR overlay `overlays/disaster-recovery/` patches CNPG `Cluster` with `spec.bootstrap.recovery`. Restore flow: apply DR overlay → CNPG restores → Flux syncs apps.
- Backup split: **volume data goes offsite** (restic to the Hetzner Storage Box, `base/offsite-backup/`). Locally we keep only what needs a fast restore and is at risk of corruption rather than site loss: databases via CNPG `barmanObjectStore` and Kubernetes objects via Velero. Local capacity is limited and sits on a RAID 5 — that absorbs disk failures, it is not a backup.
- Velero protects Kubernetes objects, not volume data: both schedules run `defaultVolumesToFsBackup: false`, so a volume is only included when its pod carries `backup.velero.io/backup-volumes`. Reason: the Garage bucket lives on the same TrueNAS pool as the source data, so an opt-out run would fill the pool. `deployNodeAgent: true` stays so single volumes can be opted in; the namespace uses privileged Pod Security labels because node-agent mounts kubelet host paths. Keep unused democratic-csi snapshotter sidecars disabled unless snapshot CRDs and a tested snapshot restore path are introduced together.
- Storage: CNPG databases use node-local `local-path`; democratic-csi iSCSI serves app RWO volumes; NFS serves large media.
- Talos + Kubernetes versions and per-node Talos config live in `base/omni-sync/cluster-template.yaml` (Omni cluster template). The `omni-sync` Deployment pushes it with `omnictl cluster template sync` on every change and every 5 min; Omni rolls upgrades node by node. Do not change nodes via `talosctl patch/upgrade`, OpenTofu machine config or the Omni UI — the sync reverts UI drift. Renovate bumps both versions (`docs/renovate.md`).
- Omni does not apply Talos bootstrap manifests (kube-proxy, CoreDNS; Flannel is disabled) on a Kubernetes upgrade; `omni-sync` does it (`omnictl cluster kubernetes manifest-sync`), only when no Talos/K8s upgrade or CA rotation is in flight and the dry-run shows a diff. Manual edits to those objects are reverted — change them via the template. CoreDNS forwards to `/etc/resolv.conf` (Talos host DNS 169.254.116.108 -> 192.168.10.1).
- Node data disk `sdb1` = Talos `ExistingVolumeConfig` `local-storage` at `/var/mnt/local-storage` (local-path + static `local` PVs). No `.machine.kubelet` / `.machine.disks` in the template: they conflict with the `KubeletConfig` document Omni writes for K8s upgrades, and kubelet only sees `/var/mnt`.
- democratic-csi node plugin uses `ISCSIADM_HOST_STRATEGY: chroot` (host `iscsiadm` via `/host`). `nsenter` breaks under Talos workload isolation (sandboxd) because hostPID no longer shows the host `iscsid`. Verify a strategy change with a fresh iSCSI PVC on an isolated and a non-isolated node.
- Ingress: NGINX with `nginx.org/*` annotations, no snippets (no forward-auth; UIs without OIDC go through an Authentik proxy provider on the embedded outpost).
- CNI: Cilium HelmRelease with its own Flux Kustomization `infra-cilium`; Flannel is deleted in the Omni template, kube-proxy stays. Cilium is excluded from Renovate automerge; config changes roll the agents. Flux cannot heal a broken CNI — emergency reinstall in `docs/runbooks/cilium.md`.
- NetworkPolicies: standard NetworkPolicy under Cilium semantics plus one CCNP for host-network sources (`base/network/network-policies/cluster/`). Big policy changes go out under `policyAuditMode` first; see `docs/runbooks/network-policies-rollout.md`.
- Never rely on `flux suspend` for infra Kustomizations: `flux-system` re-applies `clusters/main/infrastructure.yaml` and resets it.
- `base/security/sa-no-token/`: `default` ServiceAccounts with `automountServiceAccountToken: false` for existing managed namespaces. New app-owned namespaces keep this ServiceAccount beside their Namespace manifest: `infra-base` runs before `apps`, so a central entry would block namespace creation. Workloads that need API access use a dedicated SA with `automountServiceAccountToken: true` (remediation-api, n8n, mcp-server, ai-agents, operators). See issue #744.

# Work Guidance

- Prefer HelmReleases (Flux-managed) over static manifests for standard software.
- Comment complex patches inline in YAML.

# Verification

- `just validate` locally before PR.
- Run `just validate-full` when changing workload or controller manifests.

# Child DOX Index

- `base/offsite-backup/AGENTS.md` — encrypted Storage Box backups, retention, consistency, and restore verification.
