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

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/fixtures.yaml" <<'YAML'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ignored
---
apiVersion: other.example/v1
kind: Unexpected
metadata:
  name: still-validated
---
apiVersion: v1
kind: Pod
metadata:
  name: still-validated
YAML

kubectl() {
  local file="${!#}"
  local kinds
  kinds="$(yq -r -N '.kind' "$file")"
  [[ "$kinds" == $'Unexpected\nPod' ]] || return 99
  return "$apply_status"
}

apply_status=0
dry_run_server "$test_dir/fixtures.yaml"
apply_status=42
status=0
dry_run_server "$test_dir/fixtures.yaml" || status=$?
[[ "$status" -eq 42 ]]

log "CI validation regression checks passed."
