# Homelable Runbook

Homelable läuft als LXC `CT 102` auf Proxmox-Node `ugos`:

- UI: `https://homelable.f4mily.net`
- LXC: `192.168.10.148`
- UI-Port: `3000`
- MCP-Port: `8001`, LAN-only
- Authentik-Client: `homelab-homelable`
- Scan-Bereich: `192.168.10.0/24`

## Topologie

Das Canvas nutzt `LAN / vmbr0` als logischen Aggregationsknoten. OPNsense ist
Gateway für `192.168.10.0/24`; Proxmox-Hosts, TrueNAS und eindeutig erkannte
LAN-Geräte hängen daran. VM-/LXC-Beziehungen bleiben zusätzlich über ihre
Proxmox-Elternknoten sichtbar. Der Aggregationsknoten ist kein zusätzliches
physisches Switch-Gerät.

## Health und Services

```bash
ssh root@192.168.10.10 'pct exec 102 -- systemctl status homelable homelable-mcp'
curl -fsS http://192.168.10.148:8000/api/v1/health
curl -fsS https://homelable.f4mily.net/api/v1/health
```

MCP-Endpunkt:

```text
http://192.168.10.148:8001/mcp/
Header: X-API-Key: <MCP_API_KEY aus /opt/homelable/mcp/.env>
```

MCP-Key nicht in Git oder Chat speichern. Bei Verlust neuen Key erzeugen und
den MCP-Service neu installieren. Port 8001 nicht über Ingress oder WAN
veröffentlichen.

## Proxmox-Backup

Homelable-Datenbank, Konfiguration und MCP-Schlüssel liegen im LXC. Vollbackup:

```bash
ssh root@192.168.10.10 \
  'vzdump 102 --mode snapshot --compress zstd --dumpdir /var/lib/vz/dump'
```

Backup-Datei auf Offsite-Ziel kopieren und Restore regelmäßig testen. Schlüssel
im Backup wie ein Passwort behandeln.

## Scan und Gerätefreigabe

Scan zunächst nur auslösen, danach Treffer prüfen:

1. `list_pending_devices`
2. Eindeutige Geräte anhand IP, MAC, Hostname und Ports klassifizieren.
3. Bekannte Geräte freigeben; unbekannte Geräte pending lassen.
4. Keine Router-, Kamera- oder IoT-Geräte nur anhand eines offenen Webports
   benennen.

Proxmox-Importdaten sind vertrauenswürdiger als reine Netzwerk-Erkennung. Ein
bereits vorhandenes Proxmox-Kind aktualisieren, nicht als zweiten Knoten anlegen.

## OIDC-Fehler

Prüfen:

```bash
ssh root@192.168.10.10 \
  'pct exec 102 -- grep -E "^(AUTH_MODE|OIDC_)" /opt/homelable/backend/.env \
   | sed -E "s/(SECRET|KEY|TOKEN)=.*/\\1=<redacted>/"'
kubectl -n authentik get secret authentik-oidc-client-secrets
kubectl -n authentik get ingress homelable
```

Callback muss exakt lauten:

```text
https://homelable.f4mily.net/api/v1/auth/oidc/callback
```

Nach Secret- oder Blueprint-Änderung:

```bash
kubectl -n authentik rollout restart deployment/authentik-worker
kubectl -n authentik rollout status deployment/authentik-worker --timeout=180s
```

Blueprint-Status prüfen:

```bash
kubectl -n authentik create job authentik-blueprint-check-manual \
  --from=cronjob/authentik-blueprint-check
kubectl -n authentik logs -f job/authentik-blueprint-check-manual
```

## Wiederherstellung

1. Proxmox-LXC aus `vzdump` wiederherstellen.
2. DNS `homelable.f4mily.net` auf Cluster-VIP `192.168.10.245` prüfen.
3. Homelable-Services und `/api/v1/health` prüfen.
4. Authentik-Secret aus SOPS anwenden.
5. Blueprint-Status `successful` prüfen.
6. OIDC-Login und MCP-Zugriff testen.

Für Clusterverlust zuerst [Talos Backup und Restore](../disaster-recovery/talos-backup-restore.md)
ausführen.
