#!/usr/bin/env bash
# Guard Homepage's cluster discovery contract: API access must accompany cluster mode.
set -euo pipefail

ROOT="${HOMEPAGE_KUSTOMIZE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT"

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
kustomize build apps/overlays/main >"$rendered"

assert_manifest() {
  local description="$1" expression="$2"
  if ! yq ea -e ". as \$item ireduce ([]; . + [\$item]) | any_c($expression)" "$rendered" >/dev/null; then
    echo "ERROR: Homepage Kubernetes access invariant failed: $description" >&2
    return 1
  fi
}

assert_manifest "Deployment must use its dedicated SA and projected token" '
  .kind == "Deployment" and .metadata.namespace == "homepage" and .metadata.name == "homepage" and
  .spec.template.spec.serviceAccountName == "homepage" and .spec.template.spec.automountServiceAccountToken == true
'
assert_manifest "dedicated SA must default token mounting off" '
  .kind == "ServiceAccount" and .metadata.namespace == "homepage" and .metadata.name == "homepage" and
  .automountServiceAccountToken == false
'
assert_manifest "ClusterRoleBinding must bind the dedicated SA" '
  .kind == "ClusterRoleBinding" and .metadata.name == "homepage" and
  .roleRef.kind == "ClusterRole" and .roleRef.name == "homepage" and
  (.subjects | any_c(.kind == "ServiceAccount" and .namespace == "homepage" and .name == "homepage"))
'
assert_manifest "ClusterRole must contain exactly three rules" '
  .kind == "ClusterRole" and .metadata.name == "homepage" and (.rules | length == 3)
'
assert_manifest "ClusterRole must permit only read-only core discovery" '
  .kind == "ClusterRole" and .metadata.name == "homepage" and (.rules | any_c(
    (.apiGroups | contains([""])) and (.apiGroups | length == 1) and
    (.resources | contains(["namespaces", "pods", "nodes"])) and (.resources | length == 3) and
    (.verbs | contains(["get", "list"])) and (.verbs | length == 2)
  ))
'
assert_manifest "ClusterRole must permit only read-only Ingress discovery" '
  .kind == "ClusterRole" and .metadata.name == "homepage" and (.rules | any_c(
    (.apiGroups | contains(["networking.k8s.io"])) and (.apiGroups | length == 1) and
    (.resources | contains(["ingresses"])) and (.resources | length == 1) and
    (.verbs | contains(["get", "list"])) and (.verbs | length == 2)
  ))
'
assert_manifest "ClusterRole must permit only read-only metrics discovery" '
  .kind == "ClusterRole" and .metadata.name == "homepage" and (.rules | any_c(
    (.apiGroups | contains(["metrics.k8s.io"])) and (.apiGroups | length == 1) and
    (.resources | contains(["nodes", "pods"])) and (.resources | length == 2) and
    (.verbs | contains(["get", "list"])) and (.verbs | length == 2)
  ))
'

if yq ea -e '. as $item ireduce ([]; . + [$item]) | any_c(
  .kind == "Secret" and .metadata.namespace == "homepage" and
  .type == "kubernetes.io/service-account-token"
)' "$rendered" >/dev/null 2>&1; then
  echo "ERROR: Homepage must use projected tokens, not a static ServiceAccount token Secret" >&2
  exit 1
fi

echo "Homepage Kubernetes access invariant passed."
