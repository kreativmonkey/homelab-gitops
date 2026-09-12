# Talos Backup und Restore

Talos ist deklarativ, aber zwei Dinge müssen separat gesichert werden:

1. `etcd`-Snapshot — Kubernetes-Zustand, Secrets und Flux-Zustand.
2. Talos-Secrets-Bundle plus Machine Configs — nötig, um Nodes mit derselben
   Cluster-Identität neu zu erzeugen.

`GitHub main` enthält Workload-Manifeste, aber keine privaten Talos-Schlüssel.
`talosconfig`, `kubeconfig`, Secrets-Bundle und Machine Configs gehören in ein
verschlüsseltes Offsite-Backup. Niemals unverschlüsselt committen.

## Backup

```bash
cd ../homelab-infrastructure
nix develop .#talos

export TALOSCONFIG=$PWD/talos/talosconfig
export BACKUP_DIR=$PWD/talos-backups/$(date +%Y%m%d-%H%M%S)
umask 077
mkdir -p "$BACKUP_DIR"

# Privilegierte Client-Konfigurationen sichern.
cp "$TALOSCONFIG" "$BACKUP_DIR/talosconfig"
cp "$PWD/talos/kubeconfig" "$BACKUP_DIR/kubeconfig"

# Konsistenter etcd-Snapshot von einem gesunden Control Plane Node.
talosctl -n 192.168.10.41 -e 192.168.10.41 \
  etcd snapshot "$BACKUP_DIR/etcd.snapshot"

# Live Machine Config jedes Nodes sichern.
for ip in 192.168.10.41 192.168.10.42 192.168.10.43; do
  talosctl -n "$ip" -e "$ip" get mc v1alpha1 -o yaml \
    | yq eval '.spec' - > "$BACKUP_DIR/machineconfig-$ip.yaml"
done

# Integrität dokumentieren, danach Archiv verschlüsseln und offsite kopieren.
sha256sum "$BACKUP_DIR"/* > "$BACKUP_DIR/SHA256SUMS"
tar -C "$(dirname "$BACKUP_DIR")" -czf - "$(basename "$BACKUP_DIR")" \
  | age -r <OFFSITE_AGE_RECIPIENT> > "$BACKUP_DIR.tar.gz.age"
```

Der Snapshot muss von einem gesunden Control Plane Node stammen. Bei verlorenem
Quorum kann als letzte Notmaßnahme die direkte Datei `/var/lib/etcd/member/snap/db`
mit `talosctl cp` kopiert werden; dieser Snapshot ist weniger sicher konsistent
und benötigt beim Restore `--recover-skip-hash-check`.

## Restore-Reihenfolge

1. Letzten validierten Backup-Satz entschlüsseln und `SHA256SUMS` prüfen.
2. Prüfen, ob Etcd-Quorum noch wiederherstellbar ist. Vollrestore nur bei
   dauerhaft verlorenem Quorum starten.
3. Defekte Control-Plane-VMs mit gleicher Rolle, IP-Plan und Talos-Secrets-Bundle
   über `homelab-infrastructure/talos` neu provisionieren.
4. Warten, bis alle Control-Plane-Nodes in `Preparing` stehen.
5. Etcd auf genau einem Control Plane Node wiederherstellen:

   ```bash
   talosctl -n 192.168.10.41 -e 192.168.10.41 \
     bootstrap --recover-from=./etcd.snapshot
   ```

6. `kubectl get nodes` und `talosctl ... etcd members` prüfen.
7. Flux und SOPS aus OpenTofu/Terraform erneut bereitstellen.
8. CNPG aus S3 wiederherstellen: [CNPG S3 DR](cnpg-s3-dr.md).
9. Velero/App-Backups für PVC- und Applikationsdaten wiederherstellen.
10. Ingress, Authentik, Homelable und OIDC-End-to-End testen.

Nicht `EPHEMERAL` löschen, solange kein Etcd-Snapshot gesichert ist. Das löscht
lokale Etcd-Daten unwiederbringlich.

## Backup-Matrix

| Bereich | Quelle | Ziel / Prüfung |
|---|---|---|
| Talos API | `talosconfig` | verschlüsseltes Offsite-Archiv |
| Kubernetes Control Plane | `etcd.snapshot` | monatlicher Testrestore |
| Node-Rebuild | Secrets-Bundle + Machine Configs | OpenTofu/Talos-Repo + Offsite |
| Manifeste | GitHub `main` | Git-Historie und Clone |
| PostgreSQL | CNPG Barman/WAL | [CNPG S3 DR](cnpg-s3-dr.md) |
| PVCs | Velero / App-Backup | Restore-Test |
| Homelable | Proxmox `vzdump` für CT 102 | LXC-Restore auf Proxmox |

## Quellen

- [Sidero: Talos Disaster Recovery](https://docs.siderolabs.com/talos/v1.10/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery)
- [Cluster Access](../cluster-access.md)
- [Homelable Runbook](../runbooks/homelable.md)
