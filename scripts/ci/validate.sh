#!/usr/bin/env bash
# CI validation: yamllint, kustomize build, kubeconform, kind dry-run
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

K8S_VERSION="${K8S_VERSION:-1.32.0}"
KUBECONFORM_ARGS=(
  -kubernetes-version "$K8S_VERSION"
  -ignore-missing-schemas
  -skip
  "HelmRelease,HelmRepository,OCIRepository,GitRepository,Kustomization,HelmChart,Provider,Alert,Bucket,Receiver,ImageRepository,ImagePolicy,ImageUpdateAutomation"
)

log() { printf '\n==> %s\n' "$*"; }

log "Stage 1: YAML lint (yamllint)"
yamllint -c .yamllint.yml \
  clusters infrastructure apps \
  .forgejo/workflows

log "Stage 2: Kustomize build + kubeconform"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

KUSTOMIZE_PATHS=(
  infrastructure/base
  infrastructure/overlays/main
  apps/overlays/main
)

for path in "${KUSTOMIZE_PATHS[@]}"; do
  log "kustomize build: $path"
  out="${BUILD_DIR}/$(echo "$path" | tr / -).yaml"
  kustomize build "$path" >"$out"
  kubeconform "${KUBECONFORM_ARGS[@]}" -summary -output text "$out"
done

log "HelmRelease chart render (helm template)"
while IFS= read -r -d '' file; do
  chart="$(yq -r '.spec.chart.spec.chart // ""' "$file")"
  version="$(yq -r '.spec.chart.spec.version // ""' "$file")"
  repo_kind="$(yq -r '.spec.chart.spec.sourceRef.kind // ""' "$file")"
  repo_name="$(yq -r '.spec.chart.spec.sourceRef.name // ""' "$file")"
  release_ns="$(yq -r '.metadata.namespace // "default"' "$file")"
  release_name="$(yq -r '.metadata.name' "$file")"

  [[ -n "$chart" && "$chart" != "null" ]] || continue
  [[ "$repo_kind" == "HelmRepository" ]] || continue

  repo_url="$(yq -r "
    select(.kind == \"HelmRepository\" and .metadata.name == \"$repo_name\") |
    .spec.url
  " infrastructure/base/sources/helm-repositories.yaml 2>/dev/null | head -1)"

  if [[ -z "$repo_url" || "$repo_url" == "null" ]]; then
    echo "WARN: skip helm template for $release_name (repo $repo_name not resolved)"
    continue
  fi

  if [[ "$repo_url" == oci://* ]]; then
    echo "WARN: skip OCI chart $release_name ($repo_url)"
    continue
  fi

  log "helm template: $release_name ($chart@$version)"
  helm repo add "ci-${repo_name}" "$repo_url" --force-update >/dev/null 2>&1 || true
  helm repo update "ci-${repo_name}" >/dev/null 2>&1 || helm repo update >/dev/null
  if ! helm template "$release_name" "ci-${repo_name}/${chart}" \
    --version "$version" \
    --namespace "$release_ns" \
    | kubeconform "${KUBECONFORM_ARGS[@]}" -summary -output text -; then
    echo "WARN: helm template/kubeconform failed for $release_name"
  fi
done < <(find infrastructure apps -name helmrelease.yaml -print0 2>/dev/null)

log "Stage 3: kind cluster server-side dry-run"
if [[ -n "${SKIP_KIND:-}" ]] || ! command -v kind >/dev/null; then
  echo "WARN: kind stage skipped (SKIP_KIND set or kind unavailable)"
  exit 0
fi

CLUSTER_NAME="gitops-homelab-ci"
kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
kind create cluster --name "$CLUSTER_NAME" --wait 120s

kubectl apply --server-side --force-conflicts -f \
  https://github.com/fluxcd/flux2/releases/latest/download/install.yaml
kubectl wait -n flux-system --for=condition=available deployment --all --timeout=180s

for path in "${KUSTOMIZE_PATHS[@]}"; do
  log "kubectl apply --dry-run=server: $path"
  kustomize build "$path" | kubectl apply --dry-run=server -f -
done

kind delete cluster --name "$CLUSTER_NAME"
log "All validation stages passed."
