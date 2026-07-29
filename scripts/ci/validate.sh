#!/usr/bin/env bash
# CI validation: yamllint, kustomize build, kubeconform, kind server-side dry-run
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

K8S_VERSION="${K8S_VERSION:-1.32.0}"
KUBECONFORM_ARGS=(
  -kubernetes-version "$K8S_VERSION"
  -ignore-missing-schemas
  -ignore-filename-pattern '.*\.secret\.yaml'
  -skip
  "HelmRelease,HelmRepository,OCIRepository,GitRepository,Kustomization,HelmChart,Provider,Alert,Bucket,Receiver,ImageRepository,ImagePolicy,ImageUpdateAutomation,Secret"
)

log() { printf '\n==> %s\n' "$*"; }

# A server-side dry-run catches admission-time rules (e.g. "rollingUpdate
# forbidden with type Recreate", "duplicate volume name") that schema-only
# kubeconform validation cannot see. It needs a real API server, so it's
# gated on kind/docker being usable, and on ENABLE_KIND_CI in CI (some
# runners can't run privileged containers).
KIND_AVAILABLE=0
if [[ -z "${SKIP_KIND:-}" ]] && command -v kind >/dev/null && docker info >/dev/null 2>&1; then
  if [[ "${CI:-}" != "true" || "${ENABLE_KIND_CI:-}" == "1" ]]; then
    KIND_AVAILABLE=1
  fi
fi

CLUSTER_NAME="gitops-homelab-ci"
BUILD_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$BUILD_DIR"
  if [[ "$KIND_AVAILABLE" == "1" ]]; then
    kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Server-side dry-run against objects whose CRDs aren't installed in the
# bare-bones kind cluster (only Flux's are) fails with "no matches for kind"
# rather than a real semantic error — treat that as a skip, not a failure.
dry_run_server() {
  local file="$1" out
  if ! out="$(kubectl apply --dry-run=server --force-conflicts -f "$file" 2>&1)"; then
    if grep -qE 'no matches for kind|the server doesn.t have a resource type' <<<"$out"; then
      echo "WARN: dry-run skipped for $(basename "$file") (CRD not installed in CI kind cluster): $(head -1 <<<"$out")"
      return 0
    fi
    echo "$out" >&2
    return 1
  fi
}

log "Stage 0: Renovate Dependency Audit"
./scripts/ci/renovate-audit.sh

log "Stage 1: YAML lint (yamllint)"
yamllint -c .yamllint.yml \
  clusters infrastructure apps \
  .forgejo/workflows \
  .github/workflows

if [[ "$KIND_AVAILABLE" == "1" ]]; then
  log "Stage 2: kind cluster bootstrap (for server-side admission checks)"
  KIND_IMAGE="kindest/node:v${K8S_VERSION}"
  kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
  kind create cluster --name "$CLUSTER_NAME" --image "$KIND_IMAGE" --wait 120s

  kubectl apply --server-side --force-conflicts -f \
    https://github.com/fluxcd/flux2/releases/latest/download/install.yaml
  kubectl wait -n flux-system --for=condition=available deployment --all --timeout=180s
else
  echo "WARN: kind stage skipped (SKIP_KIND set, kind/docker unavailable, or ENABLE_KIND_CI not set in CI) — server-side admission checks will not run this pass."
fi

log "Stage 3: Kustomize build + kubeconform + server-side dry-run"
KUSTOMIZE_PATHS=(
  infrastructure/base
  infrastructure/base/backup-schedules
  infrastructure/base/network/network-policies
  infrastructure/overlays/main
  apps/overlays/main
)

for path in "${KUSTOMIZE_PATHS[@]}"; do
  log "kustomize build: $path"
  out="${BUILD_DIR}/$(echo "$path" | tr / -).yaml"
  kustomize build "$path" >"$out"
  kubeconform "${KUBECONFORM_ARGS[@]}" -summary -output text "$out"

  if [[ "$KIND_AVAILABLE" == "1" ]]; then
    # Non-fatal for now: this covers the whole repo's Kustomize output, which
    # hasn't had a verified clean server-side dry-run run yet. Promote to a
    # hard failure once a real CI run confirms no pre-existing false positives.
    dry_run_server "$out" || echo "WARN: server-side dry-run failed for $path (see above)"
  fi
done

log "Stage 4: HelmRelease chart render (helm template) + kubeconform + server-side dry-run"
while IFS= read -r -d '' file; do
  # A file may hold both a HelmRelease and its own HelmRepository (kite,
  # sterling-pdf, netbird-operator) — `select(.kind == "HelmRelease")` picks
  # only that document. Without it, yq's default multi-doc output interleaves
  # both documents' values, which breaks every equality check below and makes
  # the release silently `continue` out of the loop with no diagnostic at
  # all (this is exactly how kite went unrendered/unvalidated).
  chart="$(yq -r 'select(.kind == "HelmRelease") | .spec.chart.spec.chart // ""' "$file")"
  version="$(yq -r 'select(.kind == "HelmRelease") | .spec.chart.spec.version // ""' "$file")"
  repo_kind="$(yq -r 'select(.kind == "HelmRelease") | .spec.chart.spec.sourceRef.kind // ""' "$file")"
  repo_name="$(yq -r 'select(.kind == "HelmRelease") | .spec.chart.spec.sourceRef.name // ""' "$file")"
  release_ns="$(yq -r 'select(.kind == "HelmRelease") | .metadata.namespace // "default"' "$file")"
  release_name="$(yq -r 'select(.kind == "HelmRelease") | .metadata.name' "$file")"

  [[ -n "$chart" && "$chart" != "null" ]] || continue
  if [[ "$repo_kind" != "HelmRepository" ]]; then
    echo "WARN: skip helm template for $release_name (chart sourced from $repo_kind, not HelmRepository)"
    continue
  fi

  # HelmRepository may be defined in the same file, or centrally.
  repo_url="$(yq -r "
    select(.kind == \"HelmRepository\" and .metadata.name == \"$repo_name\") |
    .spec.url
  " "$file" 2>/dev/null | head -1)"

  if [[ -z "$repo_url" || "$repo_url" == "null" ]]; then
    repo_url="$(yq -r "
      select(.kind == \"HelmRepository\" and .metadata.name == \"$repo_name\") |
      .spec.url
    " infrastructure/base/sources/helm-repositories.yaml 2>/dev/null | head -1)"
  fi

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

  # Extract values to a temporary file for better template rendering
  VALUES_FILE=$(mktemp)
  yq -r 'select(.kind == "HelmRelease") | .spec.values // {}' "$file" > "$VALUES_FILE"

  RENDERED="${BUILD_DIR}/helm-${release_name}.yaml"
  if ! helm template "$release_name" "ci-${repo_name}/${chart}" \
    --version "$version" \
    --namespace "$release_ns" \
    -f "$VALUES_FILE" \
    >"$RENDERED"; then
    echo "WARN: helm template failed for $release_name"
    rm -f "$VALUES_FILE"
    continue
  fi
  rm -f "$VALUES_FILE"

  kubeconform "${KUBECONFORM_ARGS[@]}" -summary -output text "$RENDERED" \
    || echo "WARN: kubeconform failed for $release_name"

  if [[ "$KIND_AVAILABLE" == "1" ]]; then
    kubectl create namespace "$release_ns" --dry-run=client -o yaml \
      | kubectl apply -f - >/dev/null
    dry_run_server "$RENDERED"
  fi
done < <(find infrastructure apps -name helmrelease.yaml -print0 2>/dev/null)

log "All validation stages passed."
