# PVC Disk Space

Ein volles Volume kann schreibende Workloads blockieren. Bei CNPG kann ein voller Datenträger den WAL-Write stoppen und die Datenbank offline nehmen.

## Alerts

| Alert | Schwelle | Bedeutung |
|-------|----------|-----------|
| `PVCDiskSpaceLow` | frei < 15 % für 15m | iSCSI-Volume läuft voll, früh eingreifen |
| `PVCDiskSpaceCritical` | frei < 5 % für 5m | akute Disk-full-Gefahr auf iSCSI-Volume |
| `PVCDiskSpaceGrowthForecast` | iSCSI-Volume >50 Gi, linearer Fit (1d→7d) trifft Limit | stetiges Wachstum wird voraussichtlich in 7d das Limit erreichen |

Die Regeln nutzen `kubelet_volume_stats_*` nur für `truenas-iscsi`-Claims. NFS-PVs und statische lokale PVs liegen teils als Verzeichnisse auf gemeinsam genutzten Dateisystemen; kubelet meldet dafür Größe und Belegung des ganzen Dateisystems, nicht des PVC-Verzeichnisses. `local-path`-HostPath-PVs liefern keine kubelet-Volume-Stats. Drei `truenas-iscsi`-Claims haben aktuell keine Volume-Stats und sind deshalb nicht durch diese Alerts abgedeckt. Alle drei Alerts routen via `homelab_owner: platform` zu ntfy + n8n-Triage.

## Ursache prüfen

Claim, gebundenes Volume und angeforderte Größe anzeigen:

```bash
kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,PVC:.metadata.name,STATUS:.status.phase,PV:.spec.volumeName,REQUEST:.spec.resources.requests.storage
```

Im Workload `df` für Dateisystem und freien Speicher und `du` für tatsächliche Dateinutzung vergleichen. Beide Befehle im Container-Pfad des PVC ausführen:

```bash
kubectl exec -n <ns> <pod> -- df -hT <mount-path>
kubectl exec -n <ns> <pod> -- du -sxh <mount-path>
```

`df` zeigt bei lokalen Verzeichnis-PVs das ganze backing filesystem; `du` zählt Dateien im PVC-Verzeichnis. Die lokale Datenplatte hängt unter `/var/mnt/local-storage`. `local-path`-Volumes liegen darunter in `/var/mnt/local-storage/local-path`.

Für node-lokale Dateisysteme schützt zusätzlich `NodeDiskCritical`: Alarm bei unter 10 % frei für 15 Minuten. PVC-Directory-Auslastung kann daraus nicht abgeleitet werden.

## Gegenmaßnahmen

1. Bei echtem Platzmangel Daten bereinigen oder den Workload-spezifischen Speicherpfad erweitern. Ein höherer PVC-Request vergrößert ein bestehendes Volume nicht automatisch; vorhandene Volumes nur nach Prüfung der StorageClass- und Workload-spezifischen Resize-Prozedur ändern.
2. Bei CNPG WAL-/Archivwachstum und Replikatstatus prüfen; keine Dateien direkt aus `pg_wal` löschen.
3. Wachstum stoppen, etwa durch alte Daten oder nicht benötigte Dateien der Anwendung.

## Fallstricke

- `status.capacity` ist die bereitgestellte PVC-Kapazität, kein Nutzungswert.
- `PVCDiskSpaceGrowthForecast` passt eine lineare Entwicklung über 1d an. Sprunghaftes Wachstum kann einen false positive erzeugen; den Alert als Trend lesen.
- Eine gemeinsame NFS-Freigabe oder ein lokales Dateisystem kann über mehrere Mounts mehrfach als PVC-Nutzung erscheinen. Dafür gelten Node-/NAS-Dateisystemmetriken, nicht die PVC-Verzeichnisgröße.
