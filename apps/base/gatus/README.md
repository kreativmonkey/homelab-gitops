# Gatus

Health-Dashboard und Status-Seite für den Cluster.

## Deployment Strategy

Gatus nutzt `strategy: Recreate` statt RollingUpdate.

**Warum?** Gatus speichert History in SQLite auf einem RWO-iSCSI-Volume. Bei RollingUpdate startet der neue Pod bevor der alte terminiert ist – der neue kann das PVC nicht attach'en (Multi-Attach-Error) und bleibt in ContainerCreating stecken. Recreate terminiert den alten Pod zuerst.

**Problem:** Das Gatus-Chart rendert auch bei `strategy: Recreate` ein leeres `rollingUpdate: {}` mit. Kubernetes rejected das (`Forbidden: may not be specified when strategy type is 'Recreate'`).

**Lösung:** Flux `postRenderers` mit JSON-Patch nullt `rollingUpdate`:

```yaml
postRenderers:
  - kustomize:
      patches:
        - target:
            kind: Deployment
            name: gatus
          patch: '[{"op": "replace", "path": "/spec/strategy/rollingUpdate", "value": null}]'
```

## Persistence

SQLite-DB auf `truenas-iscsi` (RWO). History bleibt über Pod-Neustarts erhalten. Bei `Recreate`-bedingtem kurzzeitigem Downtime gibt's keinen Deadlock.
