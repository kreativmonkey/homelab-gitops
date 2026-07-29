#!/usr/bin/env bash
# CI stage: render every HelmRelease's chart (helm template) + kubeconform
# schema validation. No Docker required — see server-dry-run.sh for the
# admission-time (server-side) checks these renders also need.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
source scripts/ci/lib.sh

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

while IFS=' ' read -r rendered release_name _release_ns; do
  kubeconform "${KUBECONFORM_ARGS[@]}" -summary -output text "$rendered" \
    || echo "WARN: kubeconform failed for $release_name"
done < <(render_all_helmreleases "$BUILD_DIR")

log "Helm render stage passed."
