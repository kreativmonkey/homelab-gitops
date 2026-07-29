#!/usr/bin/env bash
# CI stage: kustomize build + kubeconform schema validation. No Docker required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
source scripts/ci/lib.sh

for path in "${KUSTOMIZE_PATHS[@]}"; do
  log "kustomize build: $path"
  kustomize build "$path" | kubeconform "${KUBECONFORM_ARGS[@]}" -summary -output text
done

log "Kustomize validate stage passed."
