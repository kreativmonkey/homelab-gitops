# Audit Tools — GitOps Homelab Security Scan

## Tool Selection Rationale

Consolidated from 4 parallel subagents (tech-stack, architecture, DB/state, attack-surface).

### Selection Criteria
- OSI-style open-source local CLI/engine
- Addresses repo-specific risk/workflow gap
- Practical to run locally
- Complementary (no duplication)
- Canonical/upstream tool preferred

---

## Tool Matrix

| # | Tool | Category | Detects | CLI Use Case | Integration |
|---|------|----------|---------|-------------|-------------|
| 1 | **Trivy** | Config + Image Scanner | CVE in images, IaC misconfigs, hardcoded secrets, TLS gaps | `trivy config ./apps --severity HIGH,CRITICAL` | CI gate |
| 2 | **Checkov** | IaC Security Scanner | Missing auth, weak RBAC, unencrypted connections, PSA gaps | `checkov -d ./infrastructure --framework kubernetes` | CI gate |
| 3 | **Kubesec** | K8s Manifest Risk Score | Root execution, privileged mode, hostNetwork, missing seccomp | `kubesec scan apps/**/*.yaml` | CI lint stage |
| 4 | **Gitleaks** | Git Secret Scanner | Committed API tokens, passwords, private keys | `gitleaks detect --source . --verbose` | Pre-commit hook |
| 5 | **kube-bench** | CIS Benchmark | Cluster-level CIS compliance (RBAC, PSA, audit) | `kube-bench run --targets node,policies` | Post-deploy audit |
| 6 | **Kyverno** | K8s Policy Engine | Requires OIDC on ingresses, blocks privileged, enforces digests | `kyverno apply --resource ./apps --policy ./policies` | Admission + CI |
| 7 | **Conftest** | OPA Policy-as-Code | Enforces: no latest tags, no sslmode=disable, encrypted secrets | `conftest test -p policy/ apps/base/` | CI validate |
| 8 | **Falco** | Runtime Security | Container escape, privilege escalation, suspicious syscalls | DaemonSet on cluster | Cluster runtime |
| 9 | **Grype** | SBOM Vuln Scanner | CVE in Helm chart / container dependencies | `grype sbom:./sbom.json` | Monthly scan |
| 10 | **netpol-analyzer** | Network Policy Coverage | Missing namespace isolation, lateral movement paths | `netpol-analyzer --kubeconfig kubeconfig` | Post-deploy |

---

## Why Each Tool For This Repo

### 1. Trivy (aquasecurity/trivy)
- **Repo risk**: 3x `:latest` tags (goloom, tika, teslamate), unencrypted S3 endpoints, many root-run workloads
- **CLI**: `trivy config --severity HIGH,CRITICAL ./apps ./infrastructure`
- **Covers**: Image CVEs, IaC misconfigs, exposed secrets
- **Why not Grype-only**: Trivy does config + image scanning; Grype is SBOM-only

### 2. Checkov (bridgecrewio/checkov)
- **Repo risk**: 32 Ingresses without auth, 15+ root workloads, 0 NetworkPolicies, 0 PSA
- **CLI**: `checkov -d . --framework kubernetes --skip-framework terraform`
- **Covers**: K8s CIS checks, Ingress auth, RBAC, storage security
- **Why not only kubesec**: Checkov has broader coverage (RBAC, storage, backup)

### 3. Kubesec (controlplaneio/kubesec)
- **Repo risk**: Privilege escalation (Tandoor), hostNetwork (Netbird/WatchYourLAN), root users
- **CLI**: `kubesec scan apps/base/tandoor/deployment.yaml`
- **Covers**: Per-manifest risk scoring, quick triage in CI
- **Why also**: Faster per-file feedback than Checkov; runs in CI lint stage

### 4. Gitleaks (gitleaks/gitleaks)
- **Repo risk**: `keys.txt` with AGE private key on disk, potential git history leaks
- **CLI**: `gitleaks detect --source . --report-path /audit/gitleaks-report.json`
- **Covers**: Git history scanning for committed secrets
- **Why not git-secrets**: Gitleaks has better reporting, wider rule set

### 5. kube-bench (aquasecurity/kube-bench)
- **Repo risk**: No PSA enforced, no NetworkPolicies, weak RBAC
- **CLI**: `kube-bench run --targets policies`
- **Covers**: CIS K8s benchmark (RBAC, PSA, etcd encryption, audit logging)
- **Why**: Needs live cluster; validates runtime posture vs static scanning

### 6. Kyverno (kyverno/kyverno)
- **Repo risk**: No policy enforcement at admission time; unauthenticated ingresses deployed
- **CLI**: `kyverno apply --resource=./apps --policy=./policies --cluster=true`
- **Covers**: Admission-time policy; static manifest validation in CI
- **Why not OPA**: Kyverno is Kubernetes-native (CRDs), OPA is generic

### 7. Conftest (open-policy-agent/conftest)
- **Repo risk**: No enforcement of image tags, sslmode, secret encryption
- **CLI**: `conftest test -p policy/ infrastructure/base/database/cnpg/`
- **Covers**: OPA-style policy for YAML; custom rules per pattern
- **Why also**: Custom rule engine; Kyverno for K8s-native, Conftest for generic YAML

### 8. Falco (falcosecurity/falco)
- **Repo risk**: 5 hostNetwork workloads, privileged containers (Netbird), n8n secret access
- **CLI**: DaemonSet deployment; `falco --help` for rules
- **Covers**: Runtime privilege escalation, suspicious syscalls, file access
- **Why**: Catches runtime attacks that static scanning misses

### 9. Grype (anchore/grype)
- **Repo risk**: Helm chart versions may have known CVEs
- **CLI**: `grype dir:./apps`
- **Covers**: SBOM scanning for dependency CVEs
- **Why also**: Lightweight; runs on dirs without needing image pulls

### 10. netpol-analyzer (np-guard/netpol-analyzer)
- **Repo risk**: Zero NetworkPolicies deployed; unrestricted lateral movement
- **CLI**: `netpol-analyzer --kubeconfig kubeconfig --namespace '*'`
- **Covers**: NetworkPolicy coverage gaps, suggested policies
- **Why**: Specific to the repo's biggest architectural gap (no network isolation)

---

## Quick Install

```bash
# Via go (primary for this env)
go install github.com/aquasecurity/trivy/cmd/trivy@latest
go install github.com/bridgecrewio/checkov@latest
go install github.com/controlplaneio/kubesec/v2@latest
go install github.com/gitleaks/gitleaks@latest
go install github.com/aquasecurity/kube-bench@latest
go install github.com/open-policy-agent/conftest@latest
go install github.com/anchore/grype@latest

# Via nix (alternative)
nix shell nixpkgs#trivy nixpkgs#checkov nixpkgs#kubesec nixpkgs#gitleaks

# Manual binary downloads
# Kyverno: curl -sL https://github.com/kyverno/kyverno/releases/latest/download/kyverno-cli_{os}_{arch}.tar.gz
# netpol-analyzer: https://github.com/np-guard/netpol-analyzer/releases
```
