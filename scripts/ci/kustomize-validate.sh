#!/usr/bin/env bash
# CI stage: kustomize build + kubeconform schema validation. No Docker required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
source scripts/ci/lib.sh

paths="$(kustomize_paths)"
while IFS= read -r path; do
  log "kustomize build: $path"
  kustomize build "$path" | kubeconform "${KUBECONFORM_ARGS[@]}" -summary -output text
done <<< "$paths"

bash scripts/ci/validation-test.sh
scripts/ci/homepage-kubernetes-access.sh

log "Kustomize validate stage passed."
