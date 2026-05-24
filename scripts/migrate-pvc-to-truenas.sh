#!/usr/bin/env bash
# Copy data from an existing Longhorn PVC to a new PVC on truenas-iscsi (same name).
# Usage: migrate-pvc-to-truenas.sh <namespace> <pvc-name> [size e.g. 5Gi]
set -euo pipefail

NS="${1:?namespace}"
PVC="${2:?pvc name}"
SIZE="${3:-}"
SC="truenas-iscsi"
MIG_ID="${MIG_ID:-$(date +%s)}"
MIG="${PVC}-m-${MIG_ID}"
JOB_ID="${MIG_ID}"

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "Set KUBECONFIG" >&2
  exit 1
fi

if [[ -z "$SIZE" ]]; then
  SIZE="$(kubectl get pvc -n "$NS" "$PVC" -o jsonpath='{.spec.resources.requests.storage}')"
fi

echo "==> [$NS/$PVC] scale down consumers"
kubectl get pods -A -o json | python3 -c "
import json, sys
ns, pvc = '$NS', '$PVC'
for p in json.load(sys.stdin)['items']:
  vols = p.get('spec', {}).get('volumes', [])
  if p['metadata']['namespace'] != ns:
    continue
  if any(v.get('persistentVolumeClaim', {}).get('claimName') == pvc for v in vols):
    kind = p['metadata'].get('ownerReferences', [{}])[0].get('kind', '')
    print(p['metadata']['name'])
" | while read -r pod; do
  [[ -z "$pod" ]] && continue
  echo "    deleting pod $pod"
  kubectl delete pod -n "$NS" "$pod" --wait=false 2>/dev/null || true
done

# CronJobs / Deployments: suspend cronjob, scale deployments
kubectl get cronjob -n "$NS" -o name 2>/dev/null | while read -r cj; do
  kubectl patch -n "$NS" "$cj" -p '{"spec":{"suspend":true}}' --type=merge 2>/dev/null || true
done
kubectl get deploy -n "$NS" -o json 2>/dev/null | python3 -c "
import json, sys
ns, pvc = '$NS', '$PVC'
for d in json.load(sys.stdin)['items']:
  spec = d.get('spec', {}).get('template', {}).get('spec', {})
  vols = spec.get('volumes', [])
  if any(v.get('persistentVolumeClaim', {}).get('claimName') == pvc for v in vols):
    print(d['metadata']['name'])
" | while read -r dep; do
  kubectl scale deploy -n "$NS" "$dep" --replicas=0
done

kubectl get statefulset -n "$NS" -o json 2>/dev/null | python3 -c "
import json, sys
ns, pvc = '$NS', '$PVC'
for s in json.load(sys.stdin)['items']:
  vols = s.get('spec', {}).get('template', {}).get('spec', {}).get('volumes', [])
  if any(v.get('persistentVolumeClaim', {}).get('claimName') == pvc for v in vols):
    print(s['metadata']['name'])
" | while read -r sts; do
  kubectl scale sts -n "$NS" "$sts" --replicas=0
done

sleep 5

echo "==> [$NS/$PVC] rsync longhorn -> temp $MIG"
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${MIG}
  namespace: ${NS}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${SC}
  resources:
    requests:
      storage: ${SIZE}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: mig-${JOB_ID}
  namespace: ${NS}
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: rsync
          image: alpine:3.21
          command:
            - sh
            - -c
            - |
              set -e
              apk add --no-cache rsync
              mkdir -p /dst
              rsync -aHAX /src/ /dst/ || [ -z "\$(ls -A /src 2>/dev/null)" ]
              echo done
          volumeMounts:
            - name: src
              mountPath: /src
            - name: dst
              mountPath: /dst
      volumes:
        - name: src
          persistentVolumeClaim:
            claimName: ${PVC}
        - name: dst
          persistentVolumeClaim:
            claimName: ${MIG}
EOF

kubectl wait --for=condition=complete "job/mig-${JOB_ID}" -n "$NS" --timeout=30m

echo "==> [$NS/$PVC] replace PVC"
kubectl delete pvc -n "$NS" "$PVC" --wait=false
for _ in $(seq 1 90); do
  if ! kubectl get pvc -n "$NS" "$PVC" &>/dev/null; then
    break
  fi
  phase="$(kubectl get pvc -n "$NS" "$PVC" -o jsonpath='{.status.phase}' 2>/dev/null || echo gone)"
  [[ "$phase" == "Terminating" ]] && bash "$(dirname "$0")/force-delete-pvc.sh" "$NS" "$PVC"
  sleep 5
done
if kubectl get pvc -n "$NS" "$PVC" &>/dev/null; then
  echo "ERROR: PVC $NS/$PVC still exists after delete" >&2
  exit 1
fi
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC}
  namespace: ${NS}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${SC}
  resources:
    requests:
      storage: ${SIZE}
EOF

kubectl wait --for=jsonpath='{.status.phase}'=Bound "pvc/${PVC}" -n "$NS" --timeout=10m

echo "==> [$NS/$PVC] rsync temp -> new"
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: mig-r-${JOB_ID}
  namespace: ${NS}
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: rsync
          image: alpine:3.21
          command:
            - sh
            - -c
            - |
              set -e
              apk add --no-cache rsync
              rsync -aHAX /src/ /dst/
              echo done
          volumeMounts:
            - name: src
              mountPath: /src
            - name: dst
              mountPath: /dst
      volumes:
        - name: src
          persistentVolumeClaim:
            claimName: ${MIG}
        - name: dst
          persistentVolumeClaim:
            claimName: ${PVC}
EOF

kubectl wait --for=condition=complete "job/mig-r-${JOB_ID}" -n "$NS" --timeout=30m
kubectl delete pvc -n "$NS" "$MIG" --wait=false
kubectl delete job -n "$NS" "mig-${JOB_ID}" "mig-r-${JOB_ID}" --ignore-not-found

echo "==> [$NS/$PVC] scale up"
kubectl get cronjob -n "$NS" -o name 2>/dev/null | while read -r cj; do
  kubectl patch -n "$NS" "$cj" -p '{"spec":{"suspend":false}}' --type=merge 2>/dev/null || true
done
kubectl get deploy -n "$NS" -o json 2>/dev/null | python3 -c "
import json, sys
ns, pvc = '$NS', '$PVC'
for d in json.load(sys.stdin)['items']:
  spec = d.get('spec', {}).get('template', {}).get('spec', {})
  vols = spec.get('volumes', [])
  if any(v.get('persistentVolumeClaim', {}).get('claimName') == pvc for v in vols):
    print(d['metadata']['name'])
" | while read -r dep; do
  kubectl scale deploy -n "$NS" "$dep" --replicas=1
done
kubectl get statefulset -n "$NS" -o json 2>/dev/null | python3 -c "
import json, sys
ns, pvc = '$NS', '$PVC'
for s in json.load(sys.stdin)['items']:
  vols = s.get('spec', {}).get('template', {}).get('spec', {}).get('volumes', [])
  if any(v.get('persistentVolumeClaim', {}).get('claimName') == pvc for v in vols):
    print(s['metadata']['name'])
" | while read -r sts; do
  kubectl scale sts -n "$NS" "$sts" --replicas=1
done

echo "==> [$NS/$PVC] done"
