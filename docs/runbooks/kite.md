# Kite (HelmRelease)

## Symptom

- `HelmRelease/kite` **Stalled** / rollback to chart `0.8.1`
- Pod stuck `ContainerCreating` (two ReplicaSets, one RWO PVC)
- Upgrade error: `PersistentVolumeClaim ... spec is immutable` (`storageClassName`)

## Cause

Helm cannot change `storageClassName` on an existing bound PVC. Chart upgrades (e.g. `0.8.1` → `0.12.2`) must keep the same `db.sqlite.persistence.pvc.storageClass` as the live PVC (`longhorn` on this cluster).

## Fix after GitOps change

```bash
# Clear Stalled and retry upgrade (chart 0.12.2, storageClass unchanged)
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
