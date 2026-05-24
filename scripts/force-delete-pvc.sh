#!/usr/bin/env bash
# Force-delete a PVC stuck in Terminating (Longhorn finalizers).
set -euo pipefail
NS="${1:?namespace}"; PVC="${2:?pvc name}"
kubectl patch pvc "$PVC" -n "$NS" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete pvc "$PVC" -n "$NS" --force --grace-period=0 2>/dev/null || true
