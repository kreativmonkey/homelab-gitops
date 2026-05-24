#!/usr/bin/env bash
# Staged Longhorn Helm upgrade (one minor version at a time).
# Required when jumping more than one minor release — see
# https://longhorn.io/docs/1.11.2/deploy/upgrade/
set -euo pipefail

NAMESPACE="${LONGHORN_NAMESPACE:-longhorn-system}"
RELEASE="${LONGHORN_RELEASE:-longhorn-system-longhorn}"
VALUES_FILE="${1:-}"

if [[ -z "${VALUES_FILE}" || ! -f "${VALUES_FILE}" ]]; then
  echo "Usage: $0 <helm-values.yaml>" >&2
  exit 1
fi

VERSIONS=(1.7.3 1.8.2 1.9.2 1.10.2 1.11.2)

helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
helm repo update longhorn >/dev/null

for version in "${VERSIONS[@]}"; do
  echo "==> Upgrading ${RELEASE} to chart ${version} ..."
  helm upgrade "${RELEASE}" longhorn/longhorn \
    --namespace "${NAMESPACE}" \
    --version "${version}" \
    --values "${VALUES_FILE}" \
    --wait \
    --timeout 20m
  kubectl -n "${NAMESPACE}" rollout status daemonset/longhorn-manager --timeout=300s
  echo "==> ${version} OK"
done

echo "Done. Reconcile Flux: flux reconcile helmrelease longhorn -n ${NAMESPACE}"
