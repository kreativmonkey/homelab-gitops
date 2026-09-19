# Nextcloud: Init-Container vor ausstehendem Upgrade

## What went wrong

Am 2026-09-19 blieb `deploy/nextcloud` mit `occ-oidc-setup` in
`Init:CrashLoopBackOff`. `php occ user_oidc:provider` meldete, dass der
`user_oidc`-Namespace nicht existiert; davor meldete Nextcloud ein
ausstehendes Upgrade. Der Offsite-Job fiel ebenfalls aus.

## Why it failed

OIDC-Konfiguration läuft als Init-Container. Der Hauptcontainer mit dem
offiziellen Docker-Entrypoint startet erst danach und konnte das Upgrade
des bereits auf dem PVC liegenden Codes daher nicht abschließen. Der
Backup-Preflight deutete einen fehlgeschlagenen `kubectl exec` in den noch
nicht gestarteten Hauptcontainer fälschlich als schreibgeschütztes Volume.
Aktives Volume war `nextcloud-app-node` (`local-node-static`), nicht das alte
iSCSI-PVC.

## The correct approach

`occ-db-sync` führt `php occ upgrade --no-interaction` vor OIDC-Setup aus.
Ein Upgradefehler stoppt den Pod sichtbar. Der Backup-Preflight prüft zuerst,
ob ein App-Pod läuft, und meldet fehlenden Pod getrennt von Schreibfehlern.
Nach GitOps-Rollout Nextcloud-Status, OIDC und erfolgreichen Offsite-Job prüfen.

## Prevention

Bei Nextcloud-Imagewechseln Init-Reihenfolge gegen Upgrade-Pfad prüfen.
`HelmRelease Ready` allein belegt keine verfügbare App-Replica. Backup-Logs
mit Pod-Status abgleichen, bevor ein Volume als read-only eingestuft wird.

Quelle: [Nextcloud Docker Entrypoint](https://github.com/nextcloud/docker/blob/master/docker-entrypoint.sh).
