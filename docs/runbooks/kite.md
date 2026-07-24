# Kite (HelmRelease)

## Symptom

- `HelmRelease/kite` **Stalled** / rollback to previous chart version
- Pod stuck `ContainerCreating` (two ReplicaSets, one RWO PVC)
- Upgrade error: `PersistentVolumeClaim ... spec is immutable` (`storageClassName`)
- Upgrade error: `Multi-Attach error` on `kite-kite-storage`

## Cause

Helm cannot change `storageClassName` on an existing bound PVC. Chart upgrades
must keep the same `db.sqlite.persistence.pvc.storageClass` as the live PVC.

Kite uses a `ReadWriteOnce` SQLite PVC. The chart value for the Deployment
strategy is `deploymentStrategy.type`, not `strategy.type`. If the wrong key is
used, the chart renders `RollingUpdate`; the new pod is created before the old
pod releases the PVC, and the upgrade stalls with `Multi-Attach`.

When switching an existing Deployment from `RollingUpdate` to `Recreate`, set
`deploymentStrategy.rollingUpdate: null` too. Otherwise server-side apply can
keep the old `spec.strategy.rollingUpdate` field and fail with:

```text
spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy `type` is 'Recreate'
```

## Fix after GitOps change

```bash
# Clear Stalled and retry upgrade (storageClass unchanged)
flux suspend helmrelease kite -n kite
flux resume helmrelease kite -n kite
flux reconcile helmrelease kite -n kite --with-source

kubectl get helmrelease -n kite kite
kubectl get pods -n kite
```

If an old failed pod remains:

```bash
kubectl delete pod -n kite -l app.kubernetes.io/instance=kite-kite --field-selector=status.phase!=Running
```

## New installs

For a fresh PVC you may use `longhorn-1` (cluster default). Do not change `storageClass` on a bound claim without migrating data (new PVC + copy or accept empty DB).
