# Nextcloud iSCSI Volume: Emergency Read-Only Remount

**Date**: 2026-06-13
**Severity**: high
**Affected**: app
**Status**: recurring failure mode

## What Went Wrong

Nextcloud pod entered CrashLoopBackOff (41 restarts over 35h) with:

```
/entrypoint.sh: 169: cannot create /var/www/html/nextcloud-init-sync.lock: Read-only file system
```

Init containers (`occ-db-sync`, `cleanup-mounts`, `occ-oidc-setup`, `occ-collab-setup`) all completed successfully before the main container started. The iSCSI volume `nextcloud-app-iscsi` (10Gi, ext4) was mounted read-only by the kernel.

## Why It Failed

The ext4 filesystem on `/dev/sde` (iSCSI LUN from TrueNAS) was remounted with the `emergency_ro` flag. This happens when ext4 detects filesystem corruption (I/O errors, dirty shutdown, SCSI reservation conflict, or iSCSI session loss) and the kernel automatically switches to read-only to prevent further damage.

Mount options before fix:
```
/dev/sde on .../globalmount type ext4 (rw,relatime,seclabel,stripe=2048,emergency_ro)
```

The CSI driver's `NodeStageVolume` was not called because the pod was already running with the volume attached — the kernel silently flipped the mount to read-only without detaching the iSCSI session.

The first `IScsiEmergencyReadOnly` rule was also ineffective. The default
node-exporter collector excluded all mounts below `/var/lib/kubelet`, including
CSI `globalmount` paths. VictoriaMetrics therefore had no series for the
affected iSCSI filesystem even while `node_filesystem_readonly` existed for
host filesystems.

## Rezidiv 2026-08-24/25 — und warum es 36h unbemerkt blieb

Am 2026-08-24 11:33 CEST kippte `nextcloud-app-iscsi` erneut in `emergency_ro`.
Der Kernel auf dem Node protokollierte davor:

```
sd 19:0:0:0: [sds] tag#78 timing out command, waited 180s
I/O error, dev sds, sector 4194560 op 0x1:(WRITE)
Aborting journal on device sds-8.
EXT4-fs (sds): Remounting filesystem read-only
```

Drei Punkte daran sind fuer kuenftige Diagnosen wichtig:

1. **Kein Transportabbruch.** Es gibt keine Session-Recovery-Meldung; die
   iSCSI-Verbindung stand. TrueNAS hat den Write schlicht 180 Sekunden lang
   nicht bestaetigt. Hoehere SCSI-/iscsid-Timeouts haetten das nicht
   verhindert — gewartet wurde bereits drei Minuten. Die Ursache liegt auf der
   Speicherseite (FastStorage-Contention), nicht in der Initiator-Konfiguration.
2. **Der bestehende Alarm konnte nicht feuern.** `IScsiEmergencyReadOnly` prueft
   `node_filesystem_readonly`. node-exporter setzt diese Serie nur, wenn in den
   Mount-Optionen woertlich `ro` steht. Ein abgeschaltetes ext4 steht dort aber
   als `rw,relatime,stripe=2048,emergency_ro` — die Serie blieb waehrend des
   gesamten Ausfalls auf `0`. Der Collector-Fix von 2026-08-16 war korrekt und
   noetig (die Serien existieren), er reicht fuer dieses Fehlerbild nur nicht.
3. **Gemerkt hat es das Backup.** Der Fail-Fast im Nextcloud-Offsite-Job
   (PR #794) meldete „config nicht beschreibbar" — 36 Stunden nach dem
   eigentlichen Ereignis, weil der Job nur einmal taeglich laeuft.
   `NodeISCSIDiskWriteLatencyHigh` kam wegen `for: 10m` nur bis `pending`; der
   Stall dauerte keine zehn Minuten.

Ein Pod-Neustart heilt das **nicht**: das Dateisystem behaelt sein Fehlerflag
(`Filesystem state: clean with errors`), und der naechste Schreibfehler schaltet
es sofort wieder ab. Nach dem Neustart am 24.08. lief Nextcloud genau deshalb
12 Stunden spaeter wieder ins gleiche Problem.

### Reparatur ohne laufenden Pod (bevorzugt)

Der Ablauf weiter unten stammt aus der Situation „Pod haengt im CrashLoop, LUN
ist noch angebunden". Sauberer ist es, das Volume erst freizugeben und dann
gezielt wieder anzubinden — dann kaempft kein kubelet gegen den fsck:

```bash
# 1. Flux ruhigstellen, sonst skaliert es sofort zurueck
kubectl patch helmrelease nextcloud -n nextcloud --type merge -p '{"spec":{"suspend":true}}'
kubectl patch cronjob nextcloud-cron -n nextcloud --type merge -p '{"spec":{"suspend":true}}'
kubectl scale deploy/nextcloud -n nextcloud --replicas=0

# 2. kubelet unstaged das Volume, die iSCSI-Session wird abgemeldet,
#    das Device verschwindet. IQN und Portal stehen in der PV-Spec:
kubectl get pv -o json | jq -r '.items[]
  | select(.spec.claimRef.name=="nextcloud-app-iscsi")
  | .spec.csi.volumeAttributes | "\(.iqn) \(.portal)"'

# 3. Aus dem CSI-Node-Pod des betroffenen Nodes gezielt anmelden
POD=$(kubectl get pods -n democratic-csi -o wide | awk '/talos-cp1/ && /node/ {print $1; exit}')
kubectl exec -n democratic-csi $POD -c csi-driver -- sh -c "
  iscsiadm -m node -T <IQN> -p <PORTAL> -o new
  iscsiadm -m node -T <IQN> -p <PORTAL> --login"
# Device ueber /dev/disk/by-path/ip-<PORTAL>-iscsi-<IQN>-lun-0 aufloesen

# 4. Pruefen und reparieren (muss ungemountet sein!)
kubectl exec -n democratic-csi $POD -c csi-driver -- sh -c "
  dumpe2fs -h /dev/sdX | grep -i 'Filesystem state'
  e2fsck -f -y /dev/sdX"
# Ziel: 'Filesystem state: clean' ohne 'with errors'

# 5. Wieder abmelden, Node-Record entfernen, hochfahren
kubectl exec -n democratic-csi $POD -c csi-driver -- sh -c "
  iscsiadm -m node -T <IQN> -p <PORTAL> --logout
  iscsiadm -m node -T <IQN> -p <PORTAL> -o delete"
kubectl scale deploy/nextcloud -n nextcloud --replicas=1
kubectl patch cronjob nextcloud-cron -n nextcloud --type merge -p '{"spec":{"suspend":false}}'
kubectl patch helmrelease nextcloud -n nextcloud --type merge -p '{"spec":{"suspend":false}}'
```

Danach `grep '/var/www/html/config ' /proc/mounts` im Pod: die Optionen duerfen
kein `emergency_ro` mehr enthalten.

### Betroffene Volumes clusterweit finden

`emergency_ro` steht in den Mount-Optionen, nicht im `ro`-Flag — deshalb
danach greppen, nicht nach `ro`:

```bash
for pod in <alle Pods mit iSCSI-PVC>; do
  kubectl exec -n <ns> $pod -- cat /proc/mounts |
    grep -E '^/dev/sd[b-z]' | grep -E 'emergency_ro| ro,'
done
```

Persistenter Schaden ohne aktuellen Ausfall zeigt sich am Fehlerzaehler, den
erst ein fsck zuruecksetzt:

```bash
kubectl exec -n democratic-csi <csi-node-pod> -c csi-driver -- \
  sh -c 'for d in /sys/fs/ext4/*/; do echo "$(basename $d) $(cat $d/errors_count)"; done'
```

## The Correct Approach

### 1. Identify the affected block device

```bash
# Find the CSI node pod on the node where the nextcloud pod runs
kubectl get pods -n democratic-csi -o wide | grep <node-name>

# List block devices and find the 10G device
kubectl exec -n democratic-csi <csi-node-pod> -c csi-driver -- lsblk -o NAME,SIZE,FSTYPE

# Confirm it's the right device (ext4, 10G)
kubectl exec -n democratic-csi <csi-node-pod> -c csi-driver -- sh -c "blkid /dev/sde"
```

### 2. Unmount all subpaths and the globalmount

```bash
kubectl exec -n democratic-csi <csi-node-pod> -c csi-driver -- sh -c '
# Unmount all subpath mounts first (reverse order)
for mp in $(findmnt -n -o TARGET /dev/sde 2>/dev/null | sort -r); do
  echo "Unmounting $mp"
  umount "$mp" 2>/dev/null || true
done

# Unmount globalmount
GLOBAL="<globalmount-path>"
umount "$GLOBAL" 2>/dev/null || true

# Unmount the device itself
umount /dev/sde 2>/dev/null || true
'
```

### 3. Repair the filesystem

```bash
kubectl exec -n democratic-csi <csi-node-pod> -c csi-driver -- sh -c '
e2fsck -f -y /dev/sde
'
# Expected: "recovering journal" + clean pass through all 5 checks
```

### 4. Restart the CSI node pod (forces fresh NodeStageVolume)

```bash
kubectl delete pod <csi-node-pod> -n democratic-csi
# Wait for new pod to come up
```

### 5. Manually mount at globalmount (if CSI driver doesn't auto-stage)

```bash
kubectl exec -n democratic-csi <new-csi-node-pod> -c csi-driver -- sh -c '
GLOBAL="<globalmount-path>"
mkdir -p "$GLOBAL"
mount -t ext4 /dev/sde "$GLOBAL"
'
```

### 6. Delete the stuck Nextcloud pod

```bash
kubectl delete pod -n nextcloud -l app.kubernetes.io/name=nextcloud,app.kubernetes.io/component=app
# Wait for new pod to initialize (init containers + startup probe)
```

### 7. Verify

```bash
# Confirm volume is mounted rw (no emergency_ro)
kubectl exec -n democratic-csi <csi-node-pod> -c csi-driver -- sh -c "findmnt -n -o OPTIONS /dev/sde"
# Expected: rw,relatime,seclabel,stripe=2048 (no emergency_ro)

# Confirm Nextcloud is healthy
kubectl get pods -n nextcloud -l app.kubernetes.io/name=nextcloud,app.kubernetes.io/component=app
# Expected: 1/1 Running
```

## Prevention

The Nextcloud HelmRelease currently sets only `fsGroup: 1000`. It does not set
`fsGroupChangePolicy` or `terminationGracePeriodSeconds`; rendered and live
Deployments therefore use Kubernetes' 30-second termination default. Do not
cite either setting as an applied fix until it exists declaratively and its
rendered Deployment has been verified.

**Implemented:**

| Date | Change | File |
|------|--------|------|
| ~~2026-06-13~~ | ~~StorageClass `truenas-iscsi-xfs`~~ — **war nie im Repo und nie im Cluster**; der Eintrag stimmte nicht. Am 2026-08-25 tatsaechlich angelegt (siehe unten). | — |
| 2026-08-16 | node-exporter includes CSI `globalmount` paths while still excluding pod bind mounts; VMRule `IScsiEmergencyReadOnly` checks `node_filesystem_readonly` | `apps/base/monitoring/vm-k8s-stack/helmrelease.yaml`, `apps/base/monitoring/rules/iscsi-storage-vmrule.yaml` |
| 2026-08-25 | `fs-health-exporter` (DaemonSet): exportiert `node_fs_shutdown` aus `/proc/1/mounts` und `node_fs_ext4_errors_count` aus `/sys/fs/ext4/<dev>/` — die beiden Signale, die node-exporter nicht liefert | `apps/base/fs-health-exporter/` |
| 2026-08-25 | VMRules `FilesystemShutdown` (critical) und `Ext4FilesystemErrorsPending` (warning); `NodeISCSIDiskWriteLatencyHigh` von `for: 10m` auf `3m` | `apps/base/monitoring/rules/iscsi-storage-vmrule.yaml` |
| 2026-08-25 | StorageClass `truenas-iscsi-xfs` angelegt (nicht in Benutzung, siehe Abwaegung unten) | `infrastructure/base/storage/democratic-csi/helmrelease.yaml` |

**Still recommended:**
- Nach jeder Aenderung an Collector-Filtern pruefen, ob die Quellserie
  ueberhaupt existiert — und zusaetzlich, ob sie im Fehlerfall auch *kippt*.
  Beides ist nicht dasselbe: die `globalmount`-Serien existierten seit
  2026-08-16 korrekt und standen waehrend des Ausfalls trotzdem auf 0.
- **XFS ist kein eindeutiger Gewinn.** XFS erholt sich nach einem Transport-
  Stall besser, fuehrt aber keinen persistenten Fehlerzaehler wie
  `/sys/fs/ext4/<dev>/errors_count`, und ein XFS-Shutdown steht nur im
  Kernel-Log. Ein Wechsel kostet also genau das Signal, das diesen Ausfall
  sichtbar macht. Erst umstellen, wenn Talos-Kernel-Logs in VictoriaLogs
  landen und darauf alarmiert wird.
- Offen: Talos-Kernel-Logs nach VictoriaLogs ausleiten. `talosctl dmesg` ist
  fluechtig — auf cp1 war das ausloesende Ereignis vom 24.08. beim Debugging
  am 25.08. bereits aus dem Ringpuffer gerollt.
- Offen: Ursache auf der Speicherseite. TrueNAS meldet beide Pools `healthy`
  mit 0 Read-/Write-/Checksum-Fehlern, waehrend Writes >180s haengen —
  die ZFS-Zaehler sehen diese Contention nicht.

## Related

- Learning: [democratic-csi-pvc-resize-permission-denied.md](democratic-csi-pvc-resize-permission-denied.md) — related iSCSI issue on Talos
- Files: `apps/base/nextcloud/helmrelease.yaml`
- Files: `infrastructure/base/storage/democratic-csi/helmrelease.yaml`
- Runbook: `docs/runbooks/nextcloud-init-crashloop.md`
