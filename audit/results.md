# Audit Results Summary

## Tools Run

### Kubesec v2.14.2
- **Files scanned**: tandoor, netbird, unifi-controller, watchyourlan, jellyfin deployments
- **Results file**: See report for per-manifest scores

### Gitleaks v8.30.1
- **Disk scan**: 4 leaks (AGE key, kubeconfig EC key, talosconfig ED25519 key, template placeholder)
- **Git history scan**: 11 leaks across 728 commits (kubeconfig×3 commits, talosconfig, SearXNG secret_key, AWS secret key, README example, age public key in docs)
- **Reports**: `gitleaks-report.json` (no-git), `gitleaks-git-report.json` (with git history)

## Tools Blocked
- **Trivy**: Go build failed (incompatible Go version with encoding/json/v2)
- **Checkov**: Not available via nixpkgs or pip
- **kube-bench**: Needs live cluster
- **Kyverno CLI**: Not installed in environment
- **Conftest**: Not installed in environment

## Report
Full report with 34-item risk register → `audit/security_audit_040626.md`
