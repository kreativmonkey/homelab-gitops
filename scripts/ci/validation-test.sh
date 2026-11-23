#!/usr/bin/env bash
# Regression checks for Flux path discovery and dry-run error classification.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/ci/lib.sh

paths="$(kustomize_paths)"
grep -Fxq infrastructure/base/network/cilium <<< "$paths"
grep -Fxq infrastructure/overlays/disaster-recovery <<< "$paths"
if grep -Eq '^(clusters/main|---|null)$' <<< "$paths"; then
  echo "Kustomize paths contain a bootstrap root or non-path output" >&2
  exit 1
fi

kubectl() {
  printf '%s\n' "$diagnostics" >&2
  return 1
}

diagnostics='resource mapping not found for name: "test" namespace: "example" from "render.yaml": no matches for kind "Certificate" in version "cert-manager.io/v1"
ensure CRDs are installed first'
dry_run_server render.yaml >/dev/null 2>&1
diagnostics+=$'\nError from server (Invalid): test Pod is invalid'
if dry_run_server render.yaml >/dev/null 2>&1; then
  echo "A missing CRD must not hide another admission error" >&2
  exit 1
fi

diagnostics='resource mapping not found for name: "test" namespace: "" from "render.yaml": no matches for kind "Unexpected" in version "other.example/v1"
ensure CRDs are installed first'
if dry_run_server render.yaml >/dev/null 2>&1; then
  echo "An unexpected missing CRD must fail validation" >&2
  exit 1
fi

log "CI validation regression checks passed."
