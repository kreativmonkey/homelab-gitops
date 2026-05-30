#!/usr/bin/env bash
# Remove chart-managed default VMRules left over after switching to defaultRules.create: false.
# Safe: keeps homelab-platform-* and workload-remediation VMRules (separate Flux Kustomization).
set -euo pipefail

NS="${1:-monitoring}"

echo "VMRules in ${NS} before cleanup:"
kubectl get vmrule -n "${NS}" -o custom-columns=NAME:.metadata.name,MANAGED:.metadata.labels.app\\.kubernetes\\.io/managed-by,CHART:.metadata.labels.helm\\.sh/chart 2>/dev/null || true

mapfile -t CHART_RULES < <(
  kubectl get vmrule -n "${NS}" -o json \
    | jq -r '.items[]
      | select(
          .metadata.labels["app.kubernetes.io/managed-by"] == "Helm"
          and (.metadata.labels["app.kubernetes.io/name"] // "") == "victoria-metrics-k8s-stack"
        )
      | .metadata.name'
)

if ((${#CHART_RULES[@]} == 0)); then
  echo "No chart default VMRules to delete."
  exit 0
fi

echo "Deleting ${#CHART_RULES[@]} chart VMRule(s)…"
kubectl delete vmrule -n "${NS}" "${CHART_RULES[@]}"

echo "Reconcile HelmRelease so vm-k8s-stack stays in sync:"
echo "  flux reconcile helmrelease vm-k8s-stack -n ${NS}"
