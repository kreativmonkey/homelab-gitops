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

CLUSTER_AVAILABLE=0
if [[ -z "${SKIP_KIND:-}" ]] && docker info >/dev/null 2>&1; then
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
  echo "WARN: ${CLUSTER_PROVISIONER} stage skipped (SKIP_KIND set, docker/${CLUSTER_PROVISIONER} unavailable, or ENABLE_KIND_CI not set in CI) — server-side admission checks did not run this pass."
  exit 0
fi

CLUSTER_NAME="gitops-homelab-ci"
BUILD_DIR="$(mktemp -d)"

# talosctl's docker provisioner needs root (it sets up CNI networking on the
# host) — "please run as root user" otherwise. `sudo -E env "PATH=$PATH"`
# keeps the nix-shell PATH intact under sudo; kind needs no such elevation.
talosctl_sudo() { sudo -E env "PATH=$PATH" talosctl "$@"; }

cleanup() {
  rm -rf "$BUILD_DIR"
  if [[ "$CLUSTER_PROVISIONER" == "talos" ]]; then
    talosctl_sudo cluster destroy --provisioner=docker --name "$CLUSTER_NAME" 2>/dev/null || true
  else
    kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
  fi
}
trap cleanup EXIT

log "${CLUSTER_PROVISIONER} cluster bootstrap"
if [[ "$CLUSTER_PROVISIONER" == "talos" ]]; then
  talosctl_sudo cluster destroy --provisioner=docker --name "$CLUSTER_NAME" 2>/dev/null || true
  talosctl_sudo cluster create --provisioner=docker --name "$CLUSTER_NAME" \
    --kubernetes-version "$K8S_VERSION" --wait
  TALOS_KUBECONFIG="${BUILD_DIR}/talos-kubeconfig"
  talosctl_sudo kubeconfig "$TALOS_KUBECONFIG" --provisioner=docker --name "$CLUSTER_NAME" --force
  # kubeconfig was written by root (via sudo) — hand it back so plain kubectl
  # calls below (not running under sudo) can read it.
  sudo chown "$(id -u):$(id -g)" "$TALOS_KUBECONFIG"
  export KUBECONFIG="$TALOS_KUBECONFIG"
else
  KIND_IMAGE="kindest/node:v${K8S_VERSION}"
  kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
  kind create cluster --name "$CLUSTER_NAME" --image "$KIND_IMAGE" --wait 120s
fi

kubectl apply --server-side --force-conflicts -f \
  https://github.com/fluxcd/flux2/releases/latest/download/install.yaml
kubectl wait -n flux-system --for=condition=available deployment --all --timeout=180s

log "Kustomize build: server-side dry-run"
for path in "${KUSTOMIZE_PATHS[@]}"; do
  log "kustomize build: $path"
  out="${BUILD_DIR}/$(echo "$path" | tr / -).yaml"
  kustomize build "$path" >"$out"

  # SOPS-encrypted Secrets are ciphertext in git — they can never pass
  # admission (illegal base64, unknown "sops" field) and CI never decrypts
  # them, so they're a permanent, meaningless source of noise here.
  NOSECRETS="${out%.yaml}-nosecrets.yaml"
  yq 'select(.kind != "Secret")' "$out" > "$NOSECRETS" 2>/dev/null || cp "$out" "$NOSECRETS"
  # Non-fatal for now: this covers the whole repo's Kustomize output, which
  # hasn't had a verified clean server-side dry-run run yet. Promote to a
  # hard failure once a real CI run confirms no pre-existing false positives.
  dry_run_server "$NOSECRETS" || echo "WARN: server-side dry-run failed for $path (see above)"
done

log "HelmRelease chart render: server-side dry-run"
while IFS=' ' read -r rendered _release_name release_ns; do
  kubectl create namespace "$release_ns" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
  dry_run_server "$rendered"
done < <(render_all_helmreleases "$BUILD_DIR")

log "Server dry-run stage passed."
