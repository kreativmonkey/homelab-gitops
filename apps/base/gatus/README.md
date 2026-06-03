# Gatus

Health-Dashboard und Status-Seite für den Cluster.

## Deployment Strategy

Gatus nutzt `strategy: Recreate` statt RollingUpdate.

**Warum?** Gatus speichert History in SQLite auf einem RWO-iSCSI-Volume. Bei RollingUpdate startet der neue Pod bevor der alte terminiert ist – der neue kann das PVC nicht attach'en (Multi-Attach-Error) und bleibt in ContainerCreating stecken. Recreate terminiert den alten Pod zuerst.

**Chart-Verhalten:** Das Chart rendert `rollingUpdate` nur bei `type: RollingUpdate`. Mit `type: Recreate` wird es sauber weggelassen – kein `postRenderers`-Workaround nötig.

## Persistence

Helm `persistence.enabled: true` legt ein PVC unter `/data` an — **Gatus selbst** muss SQLite dort konfigurieren, sonst bleibt `storage.type: memory` (Default) und die History geht bei jedem Pod-Neustart verloren.

```yaml
persistence:
  enabled: true
  storageClass: truenas-iscsi  # RWO

config:
  storage:
    type: sqlite
    path: /data/data.db
    caching: true
```

Siehe [Helm-Chart README](https://github.com/TwiN/helm-charts/blob/master/charts/gatus/README.md) und [Gatus Storage](https://github.com/TwiN/gatus#storage).

## Authentik (OIDC)

Login per SSO auf `https://status.cluster.f4mily.net`.

1. `just gatus-authentik-oauth` (SOPS-Secret anlegen)
2. `gatus-authentik-oauth.secret.yaml` in `kustomization.yaml` eintragen
3. Flux reconcile Authentik + Gatus

Anleitung: [`docs/integrations/gatus-authentik.md`](../../../docs/integrations/gatus-authentik.md)
