# Security Audit Report — GitOps Homelab

**Date**: 2026-06-04
**Auditor**: Sisyphus Security Audit Pipeline
**Scope**: Full repository security posture review (manifest-as-code, not live cluster)

---

## Risk Register Table

| ID | Category | Risk | Severity | Likelihood | Impact | File(s) | Tool Evidence |
|----|----------|------|----------|------------|--------|---------|---------------|
| R01 | **Secrets Mgmt** | AGE private key in `keys.txt` on disk — decrypts ALL SOPS secrets | **CRITICAL** | High | Complete secret compromise | `keys.txt:1` | Gitleaks: age-secret-key |
| R02 | **Secrets Mgmt** | `kubeconfig` with EC private key on disk + 3 commits in git history | **CRITICAL** | High | Full cluster access | `kubeconfig:19` (3 commits) | Gitleaks: private-key |
| R03 | **Secrets Mgmt** | `talosconfig` with ED25519 private key on disk + 1 commit in git history | **CRITICAL** | High | Full node API access | `talosconfig:8` (1 commit) | Gitleaks: private-key |
| R04 | **Secrets Mgmt** | SearXNG `secret_key` hardcoded in plaintext ConfigMap | **HIGH** | High | Secret key exposure, session forging | `apps/base/searxng/configmap.yaml:12` | Gitleaks: generic-api-key |
| R05 | **Secrets Mgmt** | AWS secret access key in `.opencode/plans/` committed to git | **HIGH** | Medium | Cloud infrastructure access | `.opencode/plans/cloudnative-pg-implementation.md:351` | Gitleaks: generic-api-key |
| R06 | **Auth** | 32 Ingresses with NO authentication (Jellyfin, Audiobookshelf, Homer, Readeck, Speedtest-Tracker, WatchYourLAN, Paperless-ngx, Tandoor, SearXNG, Linkwarden, Kavita, Kite, PCM, Sterling-PDF, Goloom, VictoriaMetrics, pgAdmin, n8n, Uptime-Kuma, UniFi, Backrest, etc.) | **CRITICAL** | High | Data exposure, media library access, system compromise | All ingress files in `apps/base/*/` | Subagent recon (all 4) |
| R07 | **Auth** | Root domain `f4mily.net` serves Homer dashboard with NO auth | **CRITICAL** | High | Domain-level exposure | `apps/base/homer/ingress.yaml` | Subagent: attack-surface |
| R08 | **Pod Security** | `allowPrivilegeEscalation: true` on Tandoor + UniFi | **HIGH** | Medium | Container escape | `apps/base/tandoor/deployment.yaml`, `apps/base/unifi-controller/deployment.yaml` | Kubesec: AllowPrivilegeEscalation (-7 pts) |
| R09 | **Pod Security** | 15+ workloads running as `runAsUser: 0` (root) — authentic, nextcloud, audiobookshelf, jellyfin, uptime-kuma, kavita, searxng, teslamate, etc. | **HIGH** | Medium | Container escape → node compromise | Multiple `apps/base/*/` | Kubesec: advise RunAsNonRoot |
| R10 | **Pod Security** | Netbird DaemonSet: `privileged=true` + `SYS_ADMIN` + `hostNetwork=true` | **HIGH** | Medium | Host compromise via VPN agent | `apps/base/netbird/daemonset.yaml` | Kubesec: -66 pts (CapSysAdmin -30, Privileged -30, HostNetwork -9) |
| R11 | **Pod Security** | WatchYourLAN: `privileged=true` + `hostNetwork=true` | **HIGH** | Medium | Network scanning, host access | `apps/base/watchyourlan/daemonset.yaml` | Kubesec: -36 pts (Privileged -30, HostNetwork -9) |
| R12 | **Pod Security** | Forgejo runner: Docker-in-Docker with `privileged=true` | **HIGH** | Medium | CI pipeline escape | `apps/base/forgejo/runner-deployment.yaml` | Kubesec recon |
| R13 | **Supply Chain** | 3 images using `:latest` / floating tags: goloom, tika, teslamate/grafana + 2 Nextcloud images using `:release` / `:stable` | **HIGH** | Medium | Unpredictable deployments, supply chain attacks | `apps/base/goloom/deployment.yaml`, `apps/base/paperless-ngx/document-services.yaml`, `apps/base/teslamate/deployment-grafana.yaml`, `apps/base/nextcloud/appapi-harp-deployment.yaml`, `apps/base/nextcloud/whiteboard-deployment.yaml` | Subagent recon |
| R14 | **Supply Chain** | `allowInsecureImages: true` on Authentik, Nextcloud, VictoriaMetrics HelmReleases — disables image signature verification | **HIGH** | Medium | Unsigned images deployable | `apps/base/authentik/helmrelease.yaml:33`, `apps/base/nextcloud/helmrelease.yaml:46`, `apps/base/monitoring/vm-k8s-stack/helmrelease.yaml:33` | Subagent: tech-stack |
| R15 | **Supply Chain** | Renovate automerge enabled for lockFileMaintenance, nix packages, homepage/uptime-kuma patches | **MEDIUM** | Medium | Malicious version auto-deployed without review | `renovate.json:14,251,278` | Subagent: tech-stack |
| R16 | **Network** | Zero NetworkPolicies deployed — no namespace isolation, unrestricted lateral movement | **HIGH** | High | Attackers move freely between namespaces | N/A (absence of resources) | Subagent: architecture |
| R17 | **Network** | Zero PodSecurityAdmission / PSA resources — privileged containers unrestricted | **HIGH** | High | Any workload can run privileged | N/A (absence of resources) | Subagent: architecture |
| R18 | **Network** | S3 backup endpoints use HTTP, not HTTPS — credentials + data in transit unencrypted | **CRITICAL** | High | Backup data + credentials sniffable | `infrastructure/overlays/main/database-clusters/cluster.yaml:54` | Subagent: DB/state |
| R19 | **Network** | Velero backup: `insecureSkipTLSVerify=true` + HTTP endpoint — no transport security | **CRITICAL** | High | MITM on backup traffic | `infrastructure/base/backup/helmrelease.yaml:36` | Subagent: DB/state |
| R20 | **Network** | Velero backup: no encryption-at-rest configured | **HIGH** | Medium | Backup data readable if S3 accessed | `infrastructure/base/backup/helmrelease.yaml` | Subagent: DB/state |
| R21 | **Network** | PostgreSQL NodePort 30433 exposed for migrations — direct DB access from LAN | **HIGH** | Medium | DB access without auth validation | `infrastructure/overlays/main/database-clusters/postgres-restore-nodeport.yaml` | Subagent: architecture |
| R22 | **Network** | Internal network topology exposed in Homepage ConfigMap (192.168.10.x IPs, Proxmox, TrueNAS) | **HIGH** | Medium | Network mapping, targeted attacks | `apps/base/homepage/configmap.yaml` | Subagent: attack-surface |
| R23 | **Network** | TLS not enforced for CNPG client connections — `sslmode=disable` on goloom | **HIGH** | Medium | Unencrypted DB traffic within cluster | `apps/base/goloom/deployment.yaml:48` | Subagent: DB/state |
| R24 | **CI/CD** | CI workflows run on PR trigger without fork repo guard — fork PRs could access secrets | **MEDIUM** | Medium | Secret exfiltration via CI | `.forgejo/workflows/pr-validation.yaml:4`, `.github/workflows/pr-validation.yaml:4` | Subagent: attack-surface |
| R25 | **CI/CD** | Renovate PR rate limiting allows 20 PRs/day without manual review for automerge items | **LOW** | Low | Dependency confusion PRs merge unnoticed | `renovate.json:283-284` | Subagent: tech-stack |
| R26 | **RBAC** | remediation-api ClusterRole has patch/delete on deployments/pods across cluster | **MEDIUM** | Medium | Lateral movement via remediation service | `infrastructure/base/remediation-api/rbac.yaml` | Subagent: architecture |
| R27 | **RBAC** | n8n ClusterRole has list/watch on all workload types | **MEDIUM** | Low | Workload enumeration, info disclosure | `apps/base/n8n/rbac.yaml` | Subagent: architecture |
| R28 | **Runtime** | n8n `N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` — Code nodes can read all env vars including secrets | **HIGH** | Medium | Secret exfiltration via workflow code | `apps/base/n8n/helmrelease.yaml:92-93` | Subagent: tech-stack |
| R29 | **Runtime** | n8n has multiple secrets injected as env vars (GITHUB_TOKEN, LLM_API_KEY, REMEDIATION_API_KEY, NTFY_TOKEN) | **MEDIUM** | Medium | Secret leakage via env dumps, logs | `apps/base/n8n/helmrelease.yaml:107-156` | Subagent: tech-stack |
| R30 | **Runtime** | Homepage mounts ServiceAccount token unnecessarily (`automountServiceAccountToken=true`) | **LOW** | Low | Token theft → API access | `apps/base/homepage/deployment.yaml` | Subagent: architecture |
| R31 | **Config** | `automountServiceAccountToken` not explicitly disabled on 12+ workloads | **LOW** | Low | Default SA token mounted, unnecessary API surface | Multiple `apps/base/*/` | Subagent: architecture |
| R32 | **Config** | NFS exports assumed world-readable — no Kerberos/GSS auth, no `noexec`/`nosuid`/`nodev` mount options | **MEDIUM** | Low | Data access without per-user isolation | `infrastructure/base/storage/pv-nfs.yaml` | Subagent: DB/state |
| R33 | **Config** | Wildcard TLS certs for `*.f4mily.net` and `*.cluster.f4mily.net` — single point of failure | **MEDIUM** | Low | Cert compromise = all subdomains compromised | `infrastructure/base/network/certificates/` | Subagent: architecture |
| R34 | **Config** | `sslmode=disable` in goloom DB connection — no TLS for database traffic | **HIGH** | Medium | Plaintext DB credentials + data in transit | `apps/base/goloom/deployment.yaml:48` | Subagent: DB/state |

**Severity**: CRITICAL(7) | HIGH(16) | MEDIUM(8) | LOW(3)
**Total risks identified**: 34

---

## Tool Verification Results

### Kubesec v2.14.2 — Manifest Risk Scoring

| Manifest | Score | Critical Findings | Notes |
|----------|-------|-------------------|-------|
| `apps/base/tandoor/deployment.yaml` | **-2** | AllowPrivilegeEscalation: true (-7) | Recipe app can escalate to root |
| `apps/base/netbird/daemonset.yaml` | **-66** | SYS_ADMIN (-30), Privileged (-30), HostNetwork (-9) | Justified for VPN, highest risk |
| `apps/base/unifi-controller/deployment.yaml` | **-2** | AllowPrivilegeEscalation: true (-7) | Controller can escalate |
| `apps/base/watchyourlan/daemonset.yaml` | **-36** | Privileged (-30), HostNetwork (-9) | Network scanner, justified |
| `apps/base/jellyfin/deployment.yaml` | **3** | No critical issues | But missing runAsNonRoot, readOnlyRootFS |
| `apps/base/authentik/helmrelease.yaml` | N/A | HelmRelease not directly scannable | Contains allowInsecureImages: true |
| `apps/base/nextcloud/helmrelease.yaml` | N/A | HelmRelease not directly scannable | Contains allowInsecureImages: true |
| `apps/base/forgejo/runner-deployment.yaml` | N/A | privileged: true in DinD container | CI pipeline escape risk |

### Gitleaks v8.30.1 — Secret Detection

**Disk scan (gitignored files):** 4 findings
| Secret Type | File | Risk |
|-------------|------|------|
| AGE-SECRET-KEY | `keys.txt:1` | **CRITICAL** — decrypts ALL SOPS secrets |
| EC PRIVATE KEY | `kubeconfig:19` | **CRITICAL** — full cluster API access |
| ED25519 PRIVATE KEY | `talosconfig:8` | **CRITICAL** — full node API access |
| Generic API key (template) | `sparkyfitness/...secret.yaml.template:8` | Low — placeholder value |

**Git history scan (728 commits):** 11 findings across 8 unique files
| Secret | File | Commits | Risk |
|--------|------|---------|------|
| EC private key | `kubeconfig` | 3 commits | **CRITICAL** — cluster access in git history |
| ED25519 private key | `talosconfig` | 1 commit | **CRITICAL** — node access in git history |
| SearXNG secret_key | `apps/base/searxng/configmap.yaml` | 1 commit | **HIGH** — plaintext ConfigMap |
| AWS secret key | `.opencode/plans/cloudnative-pg-implementation.md` | 1 commit | **HIGH** — cloud creds in plan doc |
| Age public key | `.opencode/audit/*.md` | 1 commit | Low — public key |
| API key example | `README.md` | 2 commits | Low — placeholder |

---

## Top 10 Immediate Remediation Actions

| Priority | Action | Details | Effort |
|----------|--------|---------|--------|
| **P0** | Rotate AGE private key | `keys.txt` contains secret key on disk → generate new key, re-encrypt all `.secret.yaml`, update cluster | 2h |
| **P0** | Rotate kubeconfig credentials | EC private key exposed in git history → revoke current cert/user, issue new kubeconfig | 1h |
| **P0** | Rotate Talos config credentials | ED25519 key exposed in git history → rotate Talos API access credentials | 1h |
| **P0** | Purge secrets from git history | Use `git filter-branch` or `bfg-repo-cleaner` to strip `kubeconfig`, `talosconfig`, AWS key from git history | 1h |
| **P1** | Move AGE key off disk | `keys.txt` should be in env var (`SOPS_AGE_KEY_FILE`), not on filesystem in repo directory | 5m |
| **P1** | Add Authentik OIDC to exposed Ingresses | All 32 unauthenticated hosts need OIDC proxy — prioritize pgAdmin, VictoriaMetrics, n8n, Jellyfin, Audiobookshelf | 2d |
| **P1** | Fix S3 backup endpoints to HTTPS | Change `http://` → `https://` in CNPG clusters + Velero config; add TLS verification | 1h |
| **P1** | Move SearXNG secret_key to SOPS | Currently in plaintext ConfigMap → create `.secret.yaml`, reference as envFrom | 30m |
| **P2** | Pin floating image tags | Replace `:latest`, `:release`, `:stable` with semantic version tags; enable Renovate digest pinning | 1h |
| **P2** | Disable Renovate automerge | Remove `automerge: true` from renovate.json for all except nix packages | 15m |

**Effort estimate**: P0 items ~4h, P1 items ~3d, P2 items ongoing

---

## Tools Setup Summary

Tools used in this audit:
- **Kubesec** v2.14.2 — `nix shell nixpkgs#kubesec` (available via nixpkgs)
- **Gitleaks** v8.30.1 — `nix shell nixpkgs#gitleaks` (available via nixpkgs)
- **Not run** (blockers): Trivy (go build failed), Checkov (not in nixpkgs or pip), kube-bench (needs live cluster)

Full tool list with rationale: see `audit/tools.md`

---

## Limitations

1. **Static analysis only** — no live cluster access for runtime scanning (kube-bench, Falco, Kyverno)
2. **No IaC scanning** — Trivy and Checkov could not be installed in this environment
3. **No container image scanning** — image CVEs not assessed (requires Trivy or Grype)
4. **No network policy analysis** — netpol-analyzer not available; zero NP finding based on file absence
5. **Git history secrets** — Gitleaks scanned 728 commits; older history may exist with additional secrets
6. **HelmRelease scanning** — Kubesec cannot scan HelmRelease templates directly; only rendered manifests assessed

---

*Generated by Sisyphus Security Audit Pipeline — Phase 1: Static Manifest Analysis*
