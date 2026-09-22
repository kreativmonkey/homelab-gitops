#!/usr/bin/env bash
# One-time post-merge cleanup for Flux CRDs not declared by gotk-components.yaml.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cleanup-stale-flux-crds.sh --revision main@sha1:<merged-sha> --execute

Requires the merged revision to be Ready in both GitRepository/flux-system and
Kustomization/flux-system. Refuses cleanup if optional Flux controllers are
installed, unexpected image automation resources exist, or dependent resources
remain before a CRD deletion.
EOF
}

revision=""
execute=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --revision)
      revision="${2:-}"
      shift 2
      ;;
    --execute)
      execute=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$revision" ]] || { usage >&2; exit 2; }
[[ "$execute" == true ]] || {
  echo "Refusing mutation: pass --execute only after merge, Flux reconciliation, and review."
  exit 2
}

required_controllers=(
  notification-controller
  image-reflector-controller
  image-automation-controller
)
image_resources=(
  imagerepositories.image.toolkit.fluxcd.io
  imagepolicies.image.toolkit.fluxcd.io
  imageupdateautomations.image.toolkit.fluxcd.io
)
notification_resources=(
  alerts.notification.toolkit.fluxcd.io
  providers.notification.toolkit.fluxcd.io
  receivers.notification.toolkit.fluxcd.io
)

for command in kubectl; do
  command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 127; }
done

source_revision="$(kubectl -n flux-system get gitrepository flux-system -o jsonpath='{.status.artifact.revision}')"
sync_revision="$(kubectl -n flux-system get kustomization flux-system -o jsonpath='{.status.lastAppliedRevision}')"
[[ "$source_revision" == "$revision" ]] || { echo "GitRepository revision is $source_revision, expected $revision" >&2; exit 1; }
[[ "$sync_revision" == "$revision" ]] || { echo "Kustomization revision is $sync_revision, expected $revision" >&2; exit 1; }

for controller in "${required_controllers[@]}"; do
  if kubectl -n flux-system get deployment "$controller" >/dev/null 2>&1; then
    echo "Refusing cleanup: deployment/$controller is installed." >&2
    exit 1
  fi
done

inventory() {
  local resource="$1"
  kubectl get "$resource" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}'
}

assert_empty() {
  local resource="$1" found
  found="$(inventory "$resource")"
  if [[ -n "$found" ]]; then
    echo "Refusing CRD deletion: $resource still has dependent resources:" >&2
    printf '%s\n' "$found" >&2
    exit 1
  fi
}

printf '%s\n' 'Pre-cleanup inventory:'
for resource in "${image_resources[@]}" "${notification_resources[@]}"; do
  printf '%s: ' "$resource"
  inventory "$resource" || true
done

# Delete the only known image automation resources first. Any additional object
# survives this step and causes assert_empty to stop before CRDs are removed.
kubectl -n goloom delete imagerepository goloom --ignore-not-found
kubectl -n goloom delete imagepolicy goloom --ignore-not-found
kubectl -n goloom delete imageupdateautomation goloom --ignore-not-found

for resource in "${image_resources[@]}"; do
  assert_empty "$resource"
done
for resource in "${notification_resources[@]}"; do
  assert_empty "$resource"
done

for crd in "${image_resources[@]}" "${notification_resources[@]}"; do
  kubectl delete crd "$crd" --ignore-not-found
done

printf '%s\n' 'Post-cleanup CRD inventory:'
for crd in "${image_resources[@]}" "${notification_resources[@]}"; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    echo "Cleanup verification failed: CRD/$crd still exists." >&2
    exit 1
  fi
done
kubectl -n flux-system get deployment "${required_controllers[@]}" --ignore-not-found
printf '%s\n' 'Cleanup verified: no targeted image resources, CRDs, or optional controller deployments remain.'
