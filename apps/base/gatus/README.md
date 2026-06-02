# Gatus

Health-Dashboard und Status-Seite für den Cluster.

## Deployment Strategy

Gatus nutzt `strategy: Recreate` statt RollingUpdate.

**Warum?** Gatus speichert History in SQLite auf einem RWO-iSCSI-Volume. Bei RollingUpdate startet der neue Pod bevor der alte terminiert ist – der neue kann das PVC nicht attach'en (Multi-Attach-Error) und bleibt in ContainerCreating stecken. Recreate terminiert den alten Pod zuerst.

**Hinweis:** Chart rendert `rollingUpdate` nur bei `type: RollingUpdate` – mit `type: Recreate` wird es sauber weggelassen. Es ist kein `postRenderers`-Workaround nötig.

## Persistence

SQLite-DB auf `truenas-iscsi` (RWO). History bleibt über Pod-Neustarts erhalten. Bei `Recreate`-bedingtem kurzzeitigem Downtime gibt's keinen Deadlock.
