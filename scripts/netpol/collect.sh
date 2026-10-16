#!/usr/bin/env bash
# Stream kube-network-policies packet evaluations from every node into
# <outdir>/flows-<node>.log, one line per evaluation:
#   <Ingress|Egress> <srcPod|external> <dstPod|external> <srcIP> <dstIP:port> <proto>
# Input for simulate.py. See docs/runbooks/network-policies-rollout.md.
set -u
out=${1:?usage: collect.sh <outdir>}
mkdir -p "$out"
for node in $(kubectl get nodes -o name | cut -d/ -f2); do
  ( while :; do
      p=$(kubectl -n kube-system get pod -l k8s-app=flannel --field-selector spec.nodeName="$node" -o name)
      kubectl -n kube-system logs -f "$p" -c kube-network-policies --since=1s 2>/dev/null | awk '
        /"Evaluating packet"/ { d=$0; sub(/.*direction="/,"",d); sub(/".*/,"",d)
          s="-"; if ($0 ~ /srcPod="/) { s=$0; sub(/.*srcPod="/,"",s); sub(/".*/,"",s) }
          t="-"; if ($0 ~ /dstPod="/) { t=$0; sub(/.*dstPod="/,"",t); sub(/".*/,"",t) }
          pend=1; next }
        pend && /^\t\[[0-9]+\]/ { src=$2; sub(/:[0-9]+$/,"",src); print d, s, t, src, $3, $4; fflush(); pend=0 }'
      sleep 2   # pod restarted: reconnect
    done >> "$out/flows-$node.log" ) &
done
wait
