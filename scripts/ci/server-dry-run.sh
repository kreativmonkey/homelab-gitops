#!/usr/bin/env bash
# CI stage: bootstrap a throwaway Kubernetes cluster and run
# `kubectl apply --dry-run=server` against every rendered manifest in the
# repo. This is the only stage that needs Docker — it catches admission-time
# rules (e.g. "rollingUpdate forbidden with type Recreate", "duplicate
# volume name") that schema-only kubeconform validation (lint/
# kustomize-validate/helm-render stages) cannot see.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
source scripts/ci/lib.sh

# CLUSTER_PROVISIONER: 'kind' (default, generic node images) or 'talos'
# (production-identical Talos/Kubernetes version, via talosctl's docker
# provisioner) — opt-in via CLUSTER_PROVISIONER=talos since it's unverified
# against a real CI run so far. Gated the same way as the old combined
# kind-only stage: needs Docker, and ENABLE_KIND_CI=1 in CI (some runners,
# e.g. the Forgejo self-hosted one, may lack privileged containers).
CLUSTER_PROVISIONER="${CLUSTER_PROVISIONER:-kind}"

container_runtime=docker
if [[ "$CLUSTER_PROVISIONER" == "kind" ]]; then
  container_runtime="${KIND_EXPERIMENTAL_PROVIDER:-docker}"
fi
CLUSTER_AVAILABLE=0
if [[ -z "${SKIP_KIND:-}" ]] && "$container_runtime" info >/dev/null 2>&1; then
  if [[ "$CLUSTER_PROVISIONER" == "talos" ]] && command -v talosctl >/dev/null; then
    CLUSTER_AVAILABLE=1
  elif [[ "$CLUSTER_PROVISIONER" == "kind" ]] && command -v kind >/dev/null; then
    CLUSTER_AVAILABLE=1
  fi
  if [[ "${CI:-}" == "true" && "${ENABLE_KIND_CI:-}" != "1" ]]; then
    CLUSTER_AVAILABLE=0
  fi
fi

if [[ "$CLUSTER_AVAILABLE" != "1" ]]; then
  if [[ "${ENABLE_KIND_CI:-}" == "1" ]]; then
    echo "ERROR: required ${CLUSTER_PROVISIONER} stage unavailable." >&2
    exit 1
  fi
  echo "WARN: ${CLUSTER_PROVISIONER} stage skipped (SKIP_KIND set, docker/${CLUSTER_PROVISIONER} unavailable, or ENABLE_KIND_CI not set in CI)."
  exit 0
fi

BUILD_DIR="$(mktemp -d)"
CLUSTER_NAME="gitops-ci-${BUILD_DIR##*.}"
export KUBECONFIG="$BUILD_DIR/kubeconfig"
export TALOSCONFIG="$BUILD_DIR/talosconfig"
cleanup() {
  if [[ "$CLUSTER_PROVISIONER" == "talos" ]]; then
    talosctl cluster destroy --state "$BUILD_DIR" --name "$CLUSTER_NAME" 2>/dev/null || true
  else
    kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
  fi
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

log "${CLUSTER_PROVISIONER} cluster bootstrap"
if [[ "$CLUSTER_PROVISIONER" == "talos" ]]; then
  talosctl cluster create docker --state "$BUILD_DIR" --name "$CLUSTER_NAME" \
    --kubernetes-version "$K8S_VERSION"
else
  KIND_IMAGE="kindest/node:v${K8S_VERSION}"
  kind create cluster --name "$CLUSTER_NAME" --image "$KIND_IMAGE" --wait 120s
fi

log "Install the committed Flux CRDs"
yq 'select(.kind == "CustomResourceDefinition")' clusters/main/flux-system/gotk-components.yaml \
  >"$BUILD_DIR/flux-crds.yaml"
kubectl apply --server-side -f "$BUILD_DIR/flux-crds.yaml"
kubectl wait --for=condition=Established --timeout=60s -f "$BUILD_DIR/flux-crds.yaml"

log "Render Kustomize overlays"
paths="$(kustomize_paths)"
kustomize_builds=()
while IFS= read -r path; do
  log "kustomize build: $path"
  out="$BUILD_DIR/kustomize-${path//\//-}.yaml"
  # CI cannot admit SOPS ciphertext as Kubernetes Secret data.
  kustomize build "$path" | yq 'select(.kind != "Secret")' >"$out"
  kustomize_builds+=("$out")
done <<< "$paths"

log "Render HelmRelease charts"
render_all_helmreleases "$BUILD_DIR" >"$BUILD_DIR/helm-renders.txt"
helm_builds=()
release_namespaces=()
while IFS=' ' read -r rendered _release_name release_ns; do
  helm_builds+=("$rendered")
  release_namespaces+=("$release_ns")
done <"$BUILD_DIR/helm-renders.txt"

log "Create namespaces needed by the dry-runs"
# Dry-running a Namespace document does not create it for subsequent objects.
# Include referenced namespaces so independently reconciled roots can be tested.
{
  printf '%s\n' "${release_namespaces[@]}"
  yq -r -N '(.metadata.namespace // ""), (select(.kind == "Namespace") | .metadata.name)' \
    "${kustomize_builds[@]}" "${helm_builds[@]}"
} | sort -u | while IFS= read -r namespace; do
  [[ -n "$namespace" ]] || continue
  kubectl create namespace "$namespace" --dry-run=client -o yaml
  printf '%s\n' '---'
done >"$BUILD_DIR/namespaces.yaml"
kubectl apply --server-side -f "$BUILD_DIR/namespaces.yaml"

failed=0
for rendered in "${kustomize_builds[@]}" "${helm_builds[@]}"; do
  log "Server-side dry-run: $(basename "$rendered")"
  dry_run_server "$rendered" || failed=1
done
if [[ "$failed" != "0" ]]; then
  exit "$failed"
fi

log "Server dry-run stage passed."
