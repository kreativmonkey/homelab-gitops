# Talos: fehlende `kubelet.extraMounts` — `local`-PVs und subPath landen auf der falschen Platte

**Datum**: 2026-08-26
**Schwere**: hoch (still, keine Fehlermeldung im Normalfall)
**Betroffen**: node-lokaler Speicher clusterweit; konkret gescheitert: Nextcloud-App-Volume (PR #802, #805)
**Status**: behoben 2026-08-26 auf allen drei Nodes

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

### Rollout 2026-08-26

Angewendet per `talosctl patch machineconfig --mode=no-reboot`, Reihenfolge
cp3 → cp2 → cp1 (cp1 zuletzt, weil dort Nextcloud und ein laufendes
Offsite-Backup lagen). Talos meldet „Applied configuration without a reboot",
startet den kubelet-Task neu, die Nodes bleiben `Ready` und laufende Container
ueberleben. Alle drei CNPG-Cluster blieben `healthy`.

Verifikation je Node:

```bash
pid=$(talosctl -n <node> service kubelet | grep -oP 'Started task kubelet \(PID \K[0-9]+' | head -1)
talosctl -n <node> read /proc/$pid/mounts | grep longhorn   # -> /dev/sdb1 ...
```

Funktionsnachweis auf cp1, exakt der Wert, der vorher auseinanderlief:

| `custom_apps` | vorher | nachher |
|---|---|---|
| per hostPath | 391 431 042 B | 391 431 042 B |
| per subPath | **6 B** | **391 431 042 B** |

**Stolperstein bei der Verifikation:** `talosctl processes \| grep kubelet`
liefert nicht zuverlaessig die PID des kubelet-Tasks. Die PID aus
`talosctl service kubelet` nehmen — sonst misst man den alten Prozess und
haelt den Fix fuer wirkungslos. Ebenso: `HEALTH OK` abzufragen taugt nicht als
Warteschleife, weil es vor dem Neustart schon `OK` ist; auf einen Wechsel der
PID warten.

### Danach: Nextcloud-Umzug

Mit funktionierenden subPaths lief die Migration im dritten Anlauf durch —
`html` deterministisch aus `/usr/src/nextcloud` des Images (nicht vom alten
ext4, das „needs filesystem check" gemeldet hatte), `config`, `custom_apps`
und `data` vom iSCSI-Volume, danach vollstaendige Verifikation
(Checksummen inkl. Symlinks, `version.php` gegen das Image, `config.php`
byteidentisch) VOR dem Umschalten von `existingClaim`.

**Falle in der eigenen Pruefung:** `rsync -rcni` ohne `-l` meldet jeden
Symlink als „skipping non-regular file" und laesst die Verifikation
fehlschlagen, obwohl die Kopie (mit `-a`) korrekt ist. Zum Vergleichen
`-r -l -c -i -n --no-perms --no-owner --no-group --no-times` nehmen: prueft
Existenz, Inhalt und Linkziel, ignoriert Metadaten (das Ziel gehoert 1000:1000,
das Image root).

### Drei Nachzieharbeiten, die eine reine Dateikopie nicht abdeckt

Alle drei tauchten erst nach dem Cutover auf. `html` exakt dem Image
gleichzumachen ist richtig — aber `html` enthaelt auch **generierte** Dateien,
und der Entrypoint regeneriert sie nur, wenn er einen Versionssprung sieht.
Weil `version.php` bewusst zum Image passte, lief dieser Pfad nicht.

**1. `html/.htaccess` — Pretty-URL-Rewrites fehlten.** Unter der Zeile
`#### DO NOT CHANGE ANYTHING ABOVE THIS LINE ####` haengt ein von
`occ maintenance:update:htaccess` erzeugter Block (`RewriteRule . index.php`,
`RewriteBase /`). Im Image fehlt er. Symptom: Apache **im Pod** antwortet
`404 Not Found` auf `/login` und `403` auf `/apps/files/`, waehrend
`/status.php` 200 liefert — der Ingress ist unschuldig, im 404-Body steht
`Apache/2.4.68 (Debian)`. Behoben mit:

```bash
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ maintenance:update:htaccess
```

Nach einem Image-Upgrade erledigt der Entrypoint das wieder selbst; nach einer
Handkopie von `html` muss es **einmal manuell** laufen.

**2. `html/data/.ncdata` — Init-Container ohne Datenverzeichnis.** Die drei
`occ`-Init-Container mounteten `html` und `config`, aber nicht `data`, und
sahen als `datadirectory` das leere `html/data` aus dem Image:
`Your data directory is invalid`, Init-CrashLoop. Auf dem alten Volume lag dort
historisch ein `.ncdata` — und, verraeterisch, auch ein `nextcloud.log`: die
Init-Container hatten die ganze Zeit **neben** das echte Datenverzeichnis
geschrieben. Richtig geloest durch Mitmounten des `data`-subPath (PR #813),
nicht durch Nachlegen der Datei.

**3. `user_oidc` — Code und DB auseinandergelaufen.** `oc_appconfig` sagte
`installed_version = 8.11.0`, auf dem Volume lag 8.10.1 — auf dem alten
Volume genauso. Ursache ist der read-only-Vorfall: ein App-Update schrieb die
Version in die Datenbank, konnte den Code aber nicht auf das abgeschaltete
Dateisystem legen. Folge: `needsDbUpgrade: true`, Nextcloud antwortet Nutzern
mit **503**. Die Datenbank ist dabei die Wahrheit (ihre Migrationen sind
gelaufen), also den Code hochziehen, nicht die DB zuruecksetzen:

```bash
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ app:update user_oidc
```

`admin_audit` zeigte dieselbe Abweichung (DB 1.23.0, Code 1.24.0), ist aber
`enabled = no` und loest deshalb nichts aus.

**Merksatz:** Nach so einer Migration nicht nur Dateien vergleichen, sondern
die Anwendung befragen — `occ status` (`needsDbUpgrade`), einen echten
HTTP-Aufruf auf `/` und `/login` (nicht nur `/status.php`, das kommt an den
Rewrites vorbei) und die DB-App-Versionen gegen die Versionen im Code.

### Reste

* Auf der System-Partition (sda6, EPHEMERAL) von talos-cp1 liegen unter dem
  jetzt von sdb1 verdeckten `/var/lib/longhorn` noch ~860 MB der alten
  Fehlkopie. Sie sind ueber keinen Namespace mehr erreichbar und verschwinden
  erst beim Neuaufsetzen des Nodes. Kein Handlungsbedarf, aber es erklaert,
  warum die Partition ungewoehnlich voll ist.
* `/var/lib/longhorn/local-path/pvc-bcd7e514-…_nextcloud_nextcloud-app-local`
  auf der Datenplatte haelt noch ~1,2 GB der Kopie aus PR #802. Das PV-Objekt
  ist entfernt (Retain, es wurden keine Daten geloescht); das Verzeichnis kann
  nach ein paar stabilen Wochen von Hand weg.

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
