# Gatus

Health-Dashboard und Status-Seite für den Cluster.

## Deployment Strategy

Gatus nutzt `strategy: Recreate` statt RollingUpdate.

**Warum?** Gatus speichert History in SQLite auf einem RWO-iSCSI-Volume. Bei RollingUpdate startet der neue Pod bevor der alte terminiert ist – der neue kann das PVC nicht attach'en (Multi-Attach-Error) und bleibt in ContainerCreating stecken. Recreate terminiert den alten Pod zuerst.

**Problem:** Das Gatus-Helm-Chart rendert immer ein leeres `rollingUpdate: {}` mit, unabhängig vom `strategy.type`. Kubernetes rejected `type: Recreate` + `rollingUpdate: {}`.

**Lösung:** Flux `postRenderers` entfernt `rollingUpdate` per JSON-Patch nach dem Chart-Rendering:

```yaml
postRenderers:
  - kustomize:
      patches:
        - target:
            kind: Deployment
            name: gatus
          patch: |-
            - op: remove
              path: /spec/strategy/rollingUpdate
```

## Persistence

SQLite-DB auf `truenas-iscsi` (RWO). History bleibt über Pod-Neustarts erhalten. Bei `Recreate`-bedingtem kurzzeitigem Downtime gibt's keinen Deadlock.
