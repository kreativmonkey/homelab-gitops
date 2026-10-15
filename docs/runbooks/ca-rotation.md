# CA Rotation (Talos API & Kubernetes API) via Omni

> **Wann nötig**: Kompromittierung eines talosconfig/kubeconfig-Client-Keys,
> nach einem Cluster-Import in Omni (Label `tainted-by-importing`), oder vor
> CA-Ablauf.
>
> Zuletzt durchgeführt: **2026-10-15** (beide CAs, nach dem Omni-Import).

Omni verwaltet die CAs. Kein `talosctl rotate-ca`, kein OpenTofu — Omni würde
abweichende Secrets zurückdrehen bzw. kennt sie sonst nicht.

## Ablauf

Omni rotiert in drei Phasen, Node für Node: PRE_ROTATE (neue CA zusätzlich
akzeptiert) → ROTATE (neue CA stellt aus) → POST_ROTATE (alte CA entfernt).

```bash
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#omnictl
# Zugang über Omni (nicht über alte Client-Zertifikate) — siehe docs/cluster-access.md

# 0. Vorbereitung
omnictl kubeconfig -c homelab-kube ...   # Omni-Zugänge holen und TESTEN
talosctl -n talos-cp1 etcd snapshot ~/homelab-backups/etcd-$(date +%Y%m%d-%H%M).snapshot

# 1. Talos-CA (kein Reboot, keine Unterbrechung im Cluster; 2026-10-15: ~5 s)
omnictl cluster -n homelab-kube secret rotate talos-ca --wait-timeout 30m

# 2. Kubernetes-CA (Control Plane + kubelets starten neu; 2026-10-15: ~3 min)
omnictl cluster -n homelab-kube secret rotate kubernetes-ca --wait-timeout 60m
omnictl cluster -n homelab-kube secret rotate status
```

Während POST_ROTATE stehen kube-apiserver/-scheduler kurz in CrashLoopBackOff
(Static-Pod-Neustart) — normal, fängt sich in < 1 min.

## ⚠️ Nach der Kubernetes-CA: CSI-Volumes laufender Pods prüfen

**2026-10-15:** Beim kubelet-Neustart während der K8s-CA-Rotation rief der
kubelet auf cp1 und cp3 `NodeUnpublishVolume`/`NodeUnstageVolume` für
iSCSI-Volumes **laufender** Pods auf. democratic-csi meldete die Sessions ab,
die Geräte gingen `offline`, ext4 brach das Journal ab — 18 Volumes, die Pods
liefen auf toten Mounts weiter (Forgejo: `fork/exec /usr/bin/git: input/output
error`, Datenbanken ohne Schreibzugriff, ~2 h Metriken/Logs/KNX-Daten verloren).
Keine x509-Meldung — der TLS-Sweep unten findet das **nicht**. cp2 war nicht
betroffen.

Sofort nach der Rotation:

```bash
# Unstage-Aufrufe im Rotationsfenster je Node
for p in $(kubectl -n democratic-csi get pods -o name | grep iscsi-node); do
  kubectl -n democratic-csi logs $p -c csi-driver --since=30m --timestamps \
    | grep -E 'method: NodeUnstageVolume call' | grep -oE 'pvc-[0-9a-f-]{36}'
done | sort -u      # -> PV-Namen -> PVC -> Pods
```

Betroffene Pods **löschen** (nicht `rollout restart` — RWO), in kleinen
Gruppen (TrueNAS-Last), Datenbanken zuerst. Danach prüfen:

- `dmesg`: `EXT4-fs (sdX): recovery complete` / `mounted filesystem r/w`
- `dumpe2fs -h` je Gerät im csi-driver-Container: `Filesystem state: clean`,
  kein `FS Error count` (sonst offline `e2fsck` nötig)
- App-Logs frei von `input/output error`

Besser beim nächsten Mal: iSCSI-Workloads vorher herunterskalieren oder
direkt danach den Check oben fahren, bevor irgendetwas anderes passiert.

## Nach der Kubernetes-CA: TLS-Fehler, Pods neu starten

Pods mit API-Zugriff halten das alte CA-Bundle im Speicher und loggen danach
dauerhaft `x509: certificate signed by unknown authority`. Nur Pods mit
**anhaltenden** Fehlern neu starten (die erste Minute ist Übergang):

```bash
kubectl get pods -A --field-selector status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
| xargs -P 10 -L 1 sh -c 'c=$(kubectl -n $0 logs $1 --all-containers --since=60s 2>/dev/null \
  | grep -ciE "x509|certificate signed by unknown authority|Unauthorized"); [ "$c" -gt 0 ] && echo "$c $0/$1"'
```

Reihenfolge 2026-10-15:

1. Netz-Kern: `kubectl -n kube-system rollout restart ds/kube-proxy ds/kube-flannel deploy/coredns`
2. CNPG über den Operator (Replikas zuerst, Primary per Switchover — nicht Pods
   löschen): `kubectl -n cnpg-system annotate clusters.postgresql.cnpg.io <c> kubectl.kubernetes.io/restartedAt=$(date -u +%FT%TZ) --overwrite`.
   CNPG-Instanzen ohne API-Kontakt riskieren die Primary-Isolation-Abschaltung
   — früh erledigen.
3. Rest per `rollout restart` des Owners (2026-10-15: ingress-nginx, metrics-server,
   cert-manager-Webhooks, velero + node-agent, local-path-provisioner, vmagent,
   kite); operator-verwaltete StatefulSet-Pods (vmalertmanager) einzeln löschen.
4. Suche wiederholen, bis sie leer ist; Flux-Kustomizations und HelmReleases prüfen.

## Danach

- Alte kubeconfig/talosconfig-Dateien (OpenTofu, `~/.kube`, kubie) sind
  ungültig — neue über `omnictl kubeconfig/talosconfig` (docs/cluster-access.md).
- Omni entfernt das Label `tainted-by-importing` selbst.

## Rollback

Kein dokumentierter Abbruch in Omni. Notfall: etcd-Snapshot aus Schritt 0
(Disaster-Recovery: etcd auf allen Control-Plane-Nodes zurücksetzen, dann
`talosctl bootstrap --recover-from=<snapshot>`, siehe
docs/disaster-recovery/talos-backup-restore.md), Omni-Import-Backup unter
`~/homelab-backups/`.

## Referenzen

- [Omni: CA rotation](https://docs.siderolabs.com/omni/cluster-management/ca-rotation)
- [Omni: importing Talos clusters](https://docs.siderolabs.com/omni/cluster-management/importing-talos-clusters)
