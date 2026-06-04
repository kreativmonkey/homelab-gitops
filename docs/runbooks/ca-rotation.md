# CA Rotation (Talos API & Kubernetes API)

> **Wann nötig**: Bei Kompromittierung von `talosconfig`- oder `kubeconfig`-Client-Keys,
> oder einmal in 10 Jahren (CA-Ablauf).
>
> Talos v1.13.3, 3 Control-Plane Nodes (talos-cp{1,2,3}), `192.168.10.0/24`.

## Übersicht

Talos rotiert server-seitige Zertifikate (etcd, Kubernetes, Talos API) automatisch.
**Client-Zertifikate** (`talosconfig`, `kubeconfig`) sind Benutzerverantwortung und werden
**nicht** automatisch rotiert.

Bei Kompromittierung der Client-Private-Keys muss die **CA (Certificate Authority)**
rotiert werden, um alle alten Zertifikate zu invalidieren — das bloße Ausstellen neuer
Client-Certs reicht nicht, da die alten bis zum Ablauf gültig blieben.

`talosctl rotate-ca` (seit Talos v1.7) führt den gesamten Trust-Bundle-Wechsel automatisch durch.

## Voraussetzungen

- Gültiger `talosconfig` mit `os:admin`-Rolle
- `talosctl` installiert (via `nix develop .#talos`)
- Zugriff auf die Control-Plane Nodes via LAN (192.168.10.0/24)
- **LAN-IPs in `machine.api.advertisedAddresses` konfiguriert** (s.u. — sonst verwendet Talos Netbird-IPs)

## Phase 1: Vorbereitung

```bash
# Backup: aktuellen talosconfig sichern
cp ~/.talos/config ~/.talos/config.backup.$(date +%Y%m%d)

# Etcd-Snapshot (Notfall-Rollback)
talosctl -n 192.168.10.41 etcd snapshot etcd-pre-rotation.snapshot

# Machine-Configs aller Nodes sichern
for ip in 192.168.10.41 192.168.10.42 192.168.10.43; do
  talosctl -n $ip get machineconfig -o yaml > "machineconfig-${ip}.backup.yaml"
done

# Terraform State backup
cp terraform.tfstate terraform.tfstate.pre-rotation.backup
```

## Phase 2: Talos API CA rotieren

```bash
# Dry-Run (zeigt alle Schritte an ohne Änderungen)
talosctl -n 192.168.10.41 rotate-ca --dry-run=true --talos=true --kubernetes=false

# Echte Rotation
# UNBEDINGT Output sichern — enthält neue CA-Keys!
talosctl -n 192.168.10.41 rotate-ca --dry-run=false --talos=true --kubernetes=false 2>&1 | tee talos-ca-rotation-output.txt
```

Der Befehl:
1. Generiert neues Talos API CA (Key + Cert)
2. Fügt neues CA zu `machine.acceptedCAs` aller Nodes (beide CAs parallel trusted)
3. Tauscht `machine.ca` gegen neues CA (altes CA bleibt in `acceptedCAs`)
4. Entfernt altes CA aus `acceptedCAs`
5. Gibt neuen `talosconfig` als Datei aus

> **⚠️ CA-Private-Keys sofort sichern** und in `secrets.yaml` ablegen.

## Phase 3: Kubernetes API CA rotieren

```bash
# Erreichbarkeit prüfen
talosctl -n 192.168.10.41 version

# Dry-Run
talosctl -n 192.168.10.41 rotate-ca --dry-run=true --talos=false --kubernetes=true

# Echte Rotation
talosctl -n 192.168.10.41 rotate-ca --dry-run=false --talos=false --kubernetes=true 2>&1 | tee k8s-ca-rotation-output.txt
```

Nach der K8s CA-Rotation:
- Control-Plane Komponenten werden automatisch neugestartet
- Kubelet joined mit neuem Client-Cert neu
- **Pods ggf. manuell neustarten**: `kubectl delete pods --all --all-namespaces`

Neuen `kubeconfig` abholen:
```bash
talosctl -n 192.168.10.41 kubeconfig ~/.kube/config --force
```

## Phase 4: Terraform State aktualisieren

Nach der Rotation haben die Live-Nodes neue CAs. Das Terraform-`talos_machine_secrets`
hat noch die alten. Für zukünftiges `terraform plan` muss das synchronisiert werden:

```bash
# Altes machine_secrets aus State entfernen
terraform state rm talos_machine_secrets.this

# Neues machine_secrets mit den neuen CAs aus rotate-ca Output erzeugen
# Dazu die neuen CA-Keys aus dem Output extrahieren und in ein secrets.yaml schreiben

# Danach: terraform apply (neues machine_secrets + Configs)
terraform apply
```

**Alternativ**: Wenn Terraform nur für initiales Provisioning verwendet wird, kann der
State-Konflikt ignoriert werden — Flux läuft unabhängig.

## Phase 5: Configs im Repo ersetzen

```bash
# Neuen talosconfig einspielen
cp ./new-talosconfig /pfad/zu/homelab-infrastructure/talos/talosconfig

# Neuen kubeconfig einspielen (für Flux)
cp ./new-kubeconfig /pfad/zu/homelab-infrastructure/talos/kubeconfig
```

Beide Configs in `.gitignore` aufnehmen (falls nicht schon geschehen):
```gitignore
kubeconfig
talosconfig
```

## Phase 6: Netzwerk-Konfiguration (advertisedAddresses)

**Nur nötig, wenn `rotate-ca` Netbird- statt LAN-IPs verwendet.**

Prüfen mit:
```bash
talosctl -n 192.168.10.41 get members
```

Wenn Member-Adressen `100.96.x.x` (Netbird) enthalten, muss
`machine.api.advertisedAddresses` in der Talos-Config gesetzt werden:

```hcl
# In homelab-infrastructure/talos/main.tf als config_patch:
yamlencode({
  machine = {
    api = {
      advertisedAddresses = [var.nodes[count.index].ip_address]
    }
  }
})
```

Nach dem Patch (`terraform apply`) die Nodes neu booten:
```bash
for ip in 192.168.10.41 192.168.10.42 192.168.10.43; do
  talosctl -n $ip reboot
  talosctl -n $ip health --wait-timeout 5m
done
```

Dann erneut `rotate-ca` versuchen.

## Rollback

```bash
# Bei Fehlschlag: Machine-Configs zurücksetzen
for ip in 192.168.10.41 192.168.10.42 192.168.10.43; do
  talosctl -n $ip apply-config --file "machineconfig-${ip}.backup.yaml"
  sleep 30
done

# Etcd aus Snapshot restaurieren (nur wenn nötig)
talosctl -n 192.168.10.41 etcd restore --snapshot=etcd-pre-rotation.snapshot
```

## Referenzen

- [Talos PKI & Certificate Management](https://docs.siderolabs.com/talos/v1.13/security/cert-management)
- [Talos CA Rotation](https://docs.siderolabs.com/talos/v1.13/security/ca-rotation)
- [Terraform Provider Talos](https://registry.terraform.io/providers/siderolabs/talos/latest)
- [Cluster Access](../cluster-access.md)
