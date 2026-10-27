# Nextcloud 9.4.1: externalRedis braucht eigenes PHP-Session-Setup

## What went wrong

Beim Wechsel vom gebündelten Redis-Subchart auf `externalRedis` rendert das
Nextcloud-Chart weder das beschreibbare `php-confd`-Volume noch den
`init-redis-session-ini`-Container. Der Nextcloud-Entrypoint will trotzdem
`redis-session.ini` schreiben. Unter `runAsUser: 1000` scheitert das im
root-eigenen `/usr/local/etc/php/conf.d`.

Die zusätzlichen `occ-*`-Init-Container erben `REDIS_HOST` des Charts nicht.
Auf dem bestehenden Volume steht in `config.php` noch der alte Host
`nextcloud-redis-master`. Damit können `php occ`-Aufrufe beim Bootstrap nach
Entfernen des Subcharts scheitern.

## Why it failed

Chart 9.4.1 bindet `php-confd` und den zugehörigen Init-Container an
`redis.enabled`, nicht an `externalRedis.enabled`. Die Redis-Umgebung wird nur
an die Chart-Container für App und Cron übergeben. Eigene Init-Container
bekommen sie nicht automatisch.

## The correct approach

- `redis.enabled: false` und `externalRedis.enabled: true` setzen.
- `php-confd` als `nextcloud.extraVolumes` anlegen; per PostRenderer nur in den
  App-Container als `redis-session.ini`-Datei mounten. Ein eigener Init-Container
  erstellt die Datei zuvor.
- `REDIS_HOST` und `REDIS_HOST_PORT` in jeden eigenen PHP-Init-Container setzen,
  der `occ` aufruft. Die gespeicherte Redis-Konfiguration in `config.php` wird
  damit beim Start durch `redis.config.php` übersteuert.

## Prevention

Bei Chart-Änderungen das gepinnte Chart mit den aktuellen Values rendern,
anschließend den Flux-PostRenderer anwenden und das Ergebnis validieren. Auf
Volume, Init-Container, Dateimount und Redis-Umgebung aller `occ`-Container
prüfen. `helm template` allein testet den PostRenderer nicht.
