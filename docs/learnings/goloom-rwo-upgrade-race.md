# Goloom RWO Upgrade Race

**Date**: 2026-07-24
**Severity**: medium
**Affected**: goloom
**Status**: resolved

## What Went Wrong

Goloom `v0.2.7` did not come up after the GitOps update. The new pod stayed
in `ContainerCreating`, while the old pod kept running.

The visible symptom was:

```text
Multi-Attach error for volume "pvc-5c83afcf-7ca5-42d7-ba3b-a51d30a7a983"
Volume is already used by pod(s) goloom-6bf4f8c7d9-hwvnk
```

## Why It Failed

The application uses a `ReadWriteOnce` iSCSI PVC for `/app/data`. The old live
Deployment still had Kubernetes' default `RollingUpdate` strategy, so the
Deployment controller created the new `v0.2.7` pod before stopping the old pod.
The PVC was still attached to the old pod's node, and democratic-csi correctly
rejected the second attach.

The `v0.2.7` Goloom chart does render `strategy.type: Recreate` for RWO
persistence, but Flux hit a timing race: it started one upgrade with the new
image value while the HelmChart artifact still referenced the previous chart
revision. That produced `v0.2.7` with the old RollingUpdate strategy.

## The Correct Approach

Confirm the failure mode first:

```bash
kubectl --context admin@homelab-kube get pods -n goloom -o wide
kubectl --context admin@homelab-kube get events -n goloom --sort-by=.lastTimestamp | tail -40
kubectl --context admin@homelab-kube get deploy -n goloom goloom -o yaml | sed -n '/  strategy:/,/  template:/p'
kubectl --context admin@homelab-kube get helmchart -n flux-system goloom-goloom -o yaml
```

If the pod is blocked by RWO `Multi-Attach` and the live Deployment still says
`RollingUpdate`, patch it to match the desired chart:

```bash
kubectl --context admin@homelab-kube patch deploy -n goloom goloom \
  --type=merge \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
```

This scales down the old ReplicaSet, releases the PVC, and lets the new pod
attach the volume. Then verify:

```bash
kubectl --context admin@homelab-kube get pods -n goloom -o wide
kubectl --context admin@homelab-kube get helmrelease -n goloom goloom
kubectl --context admin@homelab-kube -n goloom run goloom-health-check \
  --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -fsS http://goloom:8080/healthz
```

Expected health response:

```json
{"status":"ok","version":"v0.2.7"}
```

## Prevention

- For apps with RWO app-data PVCs, check rendered Deployment strategy before
  merging chart or image upgrades.
- If image value and chart source both change in one GitOps pass, verify the
  HelmRelease `lastAttemptedRevision` equals the HelmChart artifact revision.
- Prefer chart-side `Recreate` for single-writer volumes; live patches are only
  emergency unblocks until Flux converges.

## Related

- `apps/base/goloom/helmrelease.yaml`
- `apps/base/goloom/gitrepository.yaml`
