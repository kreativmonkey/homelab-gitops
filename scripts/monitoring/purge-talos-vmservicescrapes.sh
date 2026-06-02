#!/usr/bin/env bash
# Delete chart VMServiceScrapes for Talos-disabled control-plane jobs (empty scrape pools).
# Safe after helmrelease sets kubeApiServer/kubeControllerManager/kubeScheduler/kubeEtcd enabled: false.
set -euo pipefail

NS="${1:-monitoring}"
RELEASE="${2:-vm-k8s-stack}"

names=(
  "${RELEASE}-kube-api-server"
  "${RELEASE}-kube-controller-manager"
  "${RELEASE}-kube-scheduler"
  "${RELEASE}-kube-etcd"
  "${RELEASE}-kube-proxy"
)

echo "VMServiceScrapes in ${NS} (Talos control-plane) before cleanup:"
kubectl get vmservicescrape -n "${NS}" -o name 2>/dev/null | grep -E 'kube-(api-server|controller-manager|scheduler|etcd)|kube-proxy' || true

to_delete=()
for n in "${names[@]}"; do
  if kubectl get "vmservicescrape/${n}" -n "${NS}" >/dev/null 2>&1; then
    to_delete+=("${n}")
  fi
done

if ((${#to_delete[@]} == 0)); then
  echo "No Talos control-plane VMServiceScrapes to delete."
  exit 0
fi

echo "Deleting ${#to_delete[@]} VMServiceScrape(s): ${to_delete[*]}"
kubectl delete vmservicescrape -n "${NS}" "${to_delete[@]}"

echo "Reconcile HelmRelease:"
echo "  flux reconcile helmrelease ${RELEASE} -n ${NS}"
