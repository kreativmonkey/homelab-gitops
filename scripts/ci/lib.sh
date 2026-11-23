#!/usr/bin/env bash
# Shared helpers for scripts/ci/*.sh — sourced, never executed directly.

# Match the Omni cluster template minor using an available kindest/node tag.
K8S_VERSION="${K8S_VERSION:-1.37.0}"
KUBECONFORM_ARGS=(
  -kubernetes-version "$K8S_VERSION"
  -ignore-missing-schemas
  -ignore-filename-pattern '.*\.secret\.yaml'
  -skip
  "HelmRelease,HelmRepository,OCIRepository,GitRepository,Kustomization,HelmChart,Provider,Alert,Bucket,Receiver,ImageRepository,ImagePolicy,ImageUpdateAutomation,Secret"
)

# The public Flux entry points own their build paths. The bootstrap path
# has no kustomization.yaml, and DR is validated even when inactive.
kustomize_paths() {
  {
    yq -r -N '
      select(.kind == "Kustomization" and
        (.apiVersion | split("/") | .[0]) == "kustomize.toolkit.fluxcd.io" and
        .spec.sourceRef.kind == "GitRepository" and .spec.sourceRef.name == "flux-system") |
      .spec.path | sub("^[.]/", "")
    ' clusters/main/*.yaml || return
    echo infrastructure/overlays/disaster-recovery
  } | sort -u
}

# stderr, not stdout: render_all_helmreleases' stdout is a data channel the
# caller parses (see below) — narration must never land on that stream.
log() { printf '\n==> %s\n' "$*" >&2; }

# A server-side dry-run catches admission-time rules (e.g. "rollingUpdate
# forbidden with type Recreate", "duplicate volume name") that schema-only
# kubeconform validation cannot see. Uses --server-side (matching how Flux's
# own controllers apply resources) rather than client-side apply: client-side
# apply stores the full previous config in a last-applied-configuration
# annotation, which large CRDs (e.g. CNPG's Cluster CRD) blow past the
# 262144-byte annotation size limit with — a real Kubernetes limitation, not
# a bug in our manifests.
#
# The sandbox has Flux's CRDs. Allow individual mapping errors for these
# known operator CRDs only. Preserve any other errors from the same apply.
dry_run_server() {
  local file="$1" errors
  errors="$(mktemp)"
  if kubectl apply --server-side --force-conflicts --dry-run=server -f "$file" > /dev/null 2>"$errors"; then
    cat "$errors" >&2
  elif ! awk '
    BEGIN {
      known["Certificate|cert-manager.io/v1"] = 1
      known["ClusterProxy|netbird.io/v1alpha1"] = 1
      known["ExternalSecret|external-secrets.io/v1"] = 1
      known["Schedule|velero.io/v1"] = 1
      known["VMPodScrape|operator.victoriametrics.com/v1beta1"] = 1
    }
    /^resource mapping not found / && /no matches for kind "/ {
      gvk = substr($0, index($0, "no matches for kind "))
      split(gvk, fields, "\"")
      if ((fields[2] "|" fields[4]) in known && fields[5] == "") {
        print "WARN: " $0
        allowed++
        hint = 1
        next
      }
    }
    hint && /^ensure CRDs are installed first$/ { hint = 0; next }
    { print; hint = 0; unexpected++ }
    END { exit (unexpected || !allowed) }
  ' "$errors" >&2; then
    rm -f "$errors"
    return 1
  fi
  rm -f "$errors"
}

# Renders every apps/infrastructure HelmRelease via `helm template` into
# files under $1 (an output directory). Skips GitRepository/OCI-sourced
# charts and unresolved repos (each with a WARN on stderr). Handles files
# that hold a HelmRepository alongside their HelmRelease (kite,
# sterling-pdf, netbird-operator) and files with more than one HelmRelease
# document (cert-manager + cert-manager-webhook-hetzner) — yq's default
# multi-doc output otherwise silently corrupts every field extracted below
# with an embedded "---", which is exactly how kite went unrendered and
# unvalidated by CI before this was fixed.
#
# stdout contract: one line per successfully rendered release,
# "<rendered-file-path> <release-name> <release-namespace>". Write the list
# to a file before consuming it so a nonzero render status fails the stage.
# Diagnostics go to stderr. Attempt all supported renders before returning
# failure so the log identifies every chart that failed.
render_all_helmreleases() {
  local out_dir="$1"
  local file release_names release_name sel
  local chart version repo_kind repo_name release_ns repo_url
  local VALUES_FILE RENDERED
  local failed=0

  while IFS= read -r -d '' file; do
    release_names="$(yq -r 'select(.kind == "HelmRelease") | .metadata.name' "$file")"
    [[ -n "$release_names" ]] || continue

    while IFS= read -r release_name; do
      [[ -n "$release_name" ]] || continue
      sel="select(.kind == \"HelmRelease\" and .metadata.name == \"$release_name\")"

      chart="$(yq -r "$sel | .spec.chart.spec.chart // \"\"" "$file")"
      version="$(yq -r "$sel | .spec.chart.spec.version // \"\"" "$file")"
      repo_kind="$(yq -r "$sel | .spec.chart.spec.sourceRef.kind // \"\"" "$file")"
      repo_name="$(yq -r "$sel | .spec.chart.spec.sourceRef.name // \"\"" "$file")"
      release_ns="$(yq -r "$sel | .metadata.namespace // \"default\"" "$file")"

      [[ -n "$chart" && "$chart" != "null" ]] || continue
      if [[ "$repo_kind" != "HelmRepository" ]]; then
        echo "WARN: skip helm template for $release_name (chart sourced from $repo_kind, not HelmRepository)" >&2
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
        echo "WARN: skip helm template for $release_name (repo $repo_name not resolved)" >&2
        continue
      fi

      if [[ "$repo_url" == oci://* ]]; then
        echo "WARN: skip OCI chart $release_name ($repo_url)" >&2
        continue
      fi

      log "helm template: $release_name ($chart@$version)"
      helm repo add "ci-${repo_name}" "$repo_url" --force-update >/dev/null 2>&1 || true
      helm repo update "ci-${repo_name}" >/dev/null 2>&1 || helm repo update >/dev/null

      VALUES_FILE=$(mktemp)
      yq -r "$sel | .spec.values // {}" "$file" > "$VALUES_FILE"

      RENDERED="${out_dir}/helm-${release_name}.yaml"
      if ! helm template "$release_name" "ci-${repo_name}/${chart}" \
        --version "$version" \
        --namespace "$release_ns" \
        -f "$VALUES_FILE" \
        >"$RENDERED"; then
        echo "ERROR: helm template failed for $release_name" >&2
        rm -f "$VALUES_FILE" "$RENDERED"
        failed=1
        continue
      fi
      rm -f "$VALUES_FILE"
      echo "$RENDERED $release_name $release_ns"
    done <<< "$release_names"
  done < <(find infrastructure apps -name helmrelease.yaml -print0 2>/dev/null)
  return "$failed"
}
