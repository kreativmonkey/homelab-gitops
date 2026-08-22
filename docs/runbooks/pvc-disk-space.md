# PVC Disk Space

PVC voll = klassischer Totalausfall, besonders fatal bei node-local `local-path`
unter CNPG: ein volles Volume blockiert den WAL-Write und die DB geht offline.

## Alerts

| Alert | Schwelle | Bedeutung |
|-------|----------|-----------|
| `PVCDiskSpaceLow` | frei < 15 % für 15m | Volume läuft voll, früh eingreifen |
| `PVCDiskSpaceCritical` | frei < 5 % für 5m | akute Disk-full-Gefahr, sofort handeln |
| `PVCDiskSpaceGrowthForecast` | >50 Gi PVC, linearer Fit (1d→7d) trifft Limit | stetiges Wachstum wird voraussichtlich in 7d das Limit erreichen |

Alle drei routen via `homelab_owner: platform` zu ntfy + n8n-Triage.

## Ursache prüfen

```bash
# freier Anteil pro PVC
kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,PVC:.metadata.name,SIZE:.spec.resources.requests.storage,USED:.status.capacity.storage

# größte Verbraucher im PVC (node-local local-path liegt unter /var/lib/local-path-provisioner)
kubectl exec -n <ns> <pod> -- df -h /data
```

## Gegenmaßnahmen

1. **Vergrößern:** `spec.resources.requests.storage` im PVC anheben (bei CNPG/`local-path`
   nur wirksam für *neue* Instanzen — bestehende via expandPVC, sofern StorageClass
   `allowVolumeExpansion: true`).
2. **Aufräumen:** bei CNPG WAL/Archive auspucken (`pg_wal`), bei Apps alte Daten löschen.
3. **Wachstum stoppen:** bei Immich/Nextcloud Duplicates/Junk entfernen, bevor vergrößert wird.

## Fallstricke

- Ein volles node-local Volume stürzt CNPG erst mit WAL-Stall ab, nicht sofort —
  `PVCDiskSpaceCritical` ist das letzte Warnsignal vor dem Ausfall.
- `PVCDiskSpaceGrowthForecast` nutzt einen linearen Fit über nur 1d; bei sprunghaftem
  Wachstum (z.B. einmaliger Import) kann er false-positives liefern — dann als Trend,
  nicht als harte Prognose lesen.
