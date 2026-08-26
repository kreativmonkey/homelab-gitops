# Talos: fehlende `kubelet.extraMounts` — `local`-PVs und subPath landen auf der falschen Platte

**Datum**: 2026-08-26
**Schwere**: hoch (still, keine Fehlermeldung im Normalfall)
**Betroffen**: node-lokaler Speicher clusterweit; konkret gescheitert: Nextcloud-App-Volume (PR #802, #805)
**Status**: Ursache bestaetigt, Fix offen (Repo `homelab-infrastructure`)

## Kurzfassung

`machine.disks` mountet die Datenplatte auf dem **Host**. Ohne
`machine.kubelet.extraMounts` sieht der **kubelet-Container** diesen Mount
nicht. Alles, was das kubelet selbst mountet — `local`-PVs und **jeder
`subPath`** — landet dadurch nicht auf der Datenplatte, sondern im
darunterliegenden, leeren Verzeichnis der System-Partition. Ohne Fehlermeldung.

## Messung (talos-cp1, 2026-08-26)

Datentraeger laut Machine-Config: `machine.disks[0]` = `/dev/sdb`,
mountpoint `/var/lib/longhorn`. `machine.kubelet.extraMounts` ist **nicht
gesetzt**.

```bash
talosctl -n 192.168.10.41 read /proc/1/mounts | grep longhorn
# /dev/sdb1 /var/lib/longhorn xfs rw,...

pid=$(talosctl -n 192.168.10.41 processes | awk '/kubelet/ && !/pause/ {print $2; exit}')
talosctl -n 192.168.10.41 read /proc/$pid/mounts | grep -c longhorn
# 0
```

Ein Pod, ein PV, dasselbe Verzeichnis, zwei Zugriffswege:

| Zugriff | `custom_apps` | `html` | `lost+found` | `df` |
|---|---|---|---|---|
| hostPath direkt (containerd) | 391 MB | 962 MB | vorhanden | `/dev/sdb1`, 85 GB frei |
| `subPath` (kubelet) | 0 (leer) | 834 MB | fehlt | — |

Eine Markerdatei, ueber den subPath geschrieben, ist auf der Datenplatte
**nicht** sichtbar; eine ueber hostPath geschriebene ist es.

Zusaetzlich scheitert ein `local`-PV auf ein Verzeichnis, das nur auf der
Datenplatte existiert, hart:

```
MountVolume.NewMounter initialization failed for volume "nextcloud-app-node":
path "/var/lib/longhorn/nextcloud-app" does not exist
```

## Warum manches trotzdem funktioniert

- **local-path-provisioner / hostPath-PVs: unbetroffen.** Der Pfad geht
  unveraendert per CRI an containerd, das im Host-Namespace auflaest. Deshalb
  liegen die CNPG-Volumes korrekt auf der Datenplatte und niemandem fiel etwas
  auf.
- **subPath auf truenas-iscsi und NFS: unbetroffen.** Dort mountet das kubelet
  das Volume selbst, der subPath-Bind zeigt in denselben Namespace. Kaputt ist
  nur der Weg auf einen Datentraeger, den das kubelet nicht sieht.

## Was das gekostet hat

Zwei Anlaeufe, das Nextcloud-App-Volume von truenas-iscsi wegzuholen (PR #802
local-path, PR #805 statisches `local`-PV), scheiterten hieran. Das
Nextcloud-Chart mountet sieben subPaths (`root`, `html`, `data`, `config`,
`custom_apps`, `tmp`, `themes`). Die Kopie landete korrekt auf der
Datenplatte, der Pod las aber aus dem leeren Schatten auf der
System-Partition, schrieb sich eine frische `config.php` und meldete
`installed: false`.

Die Fehldiagnose danach lautete „subPath funktioniert auf local-path/hostPath-PVs
nicht" und wurde in zwei Repo-Kommentaren festgeschrieben. Sie ist falsch —
subPath funktioniert, es zeigt nur in den falschen Namespace. Ein Nachtest, der
das widerlegen sollte, verstaerkte den Irrtum sogar: er verglich einen
subPath-Mount mit der Wurzel **desselben** `local`-PVs, und beide lagen im
kubelet-Namespace. Zwei Sichten auf dieselbe falsche Platte sind
erwartungsgemaess identisch.

**Merksatz:** Zum Pruefen von node-lokalem Speicher immer die Sicht per
**hostPath** gegen die Sicht per **subPath/`local`-PV** stellen, nie zwei
Zugriffe derselben Art. `/proc/mounts` taugt nicht — dort steht in beiden
Faellen `overlay`.

## Fix

Im Repo `homelab-infrastructure`, `infrastructure/talos/envs/homelab-kube`,
`extra_config_patches` erweitern (Talos-Doku „Local Storage"):

```yaml
machine:
  kubelet:
    extraMounts:
      - destination: /var/lib/longhorn
        type: bind
        source: /var/lib/longhorn
        options: [bind, rshared, rw]
```

Danach rollend anwenden (kubelet startet neu, kein Reboot) und mit einem
Testpod nachweisen, dass subPath und hostPath denselben Inhalt zeigen.

### Zweite Mine im selben Bereich

`cluster.auto.tfvars` deklariert `default_data_disks` mit
`mountpoint = "/var/mnt/local-storage"`, laufend ist aber `/var/lib/longhorn`.
Die IaC ist der Realitaet voraus: der **naechste `tofu apply` verschiebt den
Mount** — und damit die Pfade aller local-path-PVs, inklusive der
CNPG-Datenbanken. Entweder den tfvars-Wert auf den laufenden Pfad
zurueckziehen, oder den Umzug bewusst als eigene Massnahme fahren
(local-path-Config in
`infrastructure/base/storage/local-path-provisioner/configmap.yaml`
mitziehen, Marker `LEGACY-MOUNT-PATH`, CNPG-Instanzen neu aufbauen).
Beides nicht beilaeufig mit einem unbeteiligten Apply.
