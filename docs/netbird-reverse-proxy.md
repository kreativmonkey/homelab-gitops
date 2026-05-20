# Netbird Reverse Proxy — Homelab-Services ohne Port-Forwarding

Mit dem [Netbird Reverse Proxy](https://docs.netbird.io/manage/reverse-proxy) (ab v0.65) erreichst du interne Dienste von außen über HTTPS. Der Traffic läuft über die Netbird-Infrastruktur (`netbird.f4mily.net`); am Router musst du **keine** zusätzlichen Ports für einzelne Apps öffnen — nur das, was der Netbird-Host ohnehin braucht (typisch **443/tcp**, **3478/udp** für STUN).

## Architektur

```mermaid
flowchart LR
  Internet[Client im Internet]
  Traefik[Traefik auf Netbird-Host TLS passthrough]
  Proxy[netbird-proxy Container]
  Mesh[Netbird Mesh]
  K8sPeers[K8s Netbird DaemonSet]
  Ingress[NGINX Ingress 192.168.10.245:443]
  Apps[Cluster-Apps]

  Internet --> Traefik
  Traefik --> Proxy
  Proxy --> Mesh
  Mesh --> K8sPeers
  K8sPeers --> Ingress
  Ingress --> Apps
```

| Ebene | Aufgabe |
|-------|---------|
| **DNS** (`*.srv1` → `netbird.f4mily.net`) | Öffentliche Namen zeigen auf den Netbird-Server |
| **netbird-proxy** + Traefik | TLS, Zertifikate, Auth, Tunnel zum Ziel |
| **K8s Netbird-Client** | Routing-Peer: erreicht `192.168.10.0/24` und Cluster-CIDRs |
| **Ingress** | VHost-Routing per `Host`-Header (`search.f4mily.net`, …) |

## Teil 1: Netbird-Server (Docker, einmalig)

Folge der offiziellen Anleitung: [Enable Reverse Proxy](https://docs.netbird.io/selfhosted/migration/enable-reverse-proxy).

Kurzüberblick:

1. **Traefik** vor dem Netbird-Stack (TLS **passthrough** auf Port 443 — kein TLS-Terminate vor dem Proxy).
2. Container **`netbirdio/reverse-proxy`** mit `proxy.env`:
   - `NB_PROXY_DOMAIN=proxy.f4mily.net` (oder `netbird.f4mily.net`, wenn alles unter einer Domain bleiben soll)
   - `NB_PROXY_TOKEN=nbx_…` (via `netbird-server token create`)
   - `NB_PROXY_MANAGEMENT_ADDRESS=http://netbird-server:80` (im Docker-Netz)
   - `NB_PROXY_ACME_CERTIFICATES=true`
3. **DNS** beim Registrar / Hetzner:
   - `A` `netbird` → öffentliche IP des Netbird-Hosts
   - `CNAME` `proxy` → `netbird.f4mily.net`
   - `CNAME` `*.proxy` → `netbird.f4mily.net` (für Cluster-Domains wie `search.proxy.f4mily.net`)

Management und Dashboard auf **≥ 0.65** aktualisieren (`docker compose pull && up -d`).

## Teil 2: Kubernetes (GitOps)

- Namespace `netbird`: **privileged** Pod-Security (hostNetwork, NET_ADMIN).
- DaemonSet: Client **≥ 0.67** (kompatibel mit Reverse Proxy).
- **Network Routes** im Dashboard (Peers der Setup-Key-Gruppe):

| Netz | Zweck |
|------|--------|
| `10.244.0.0/16` | Pods |
| `10.96.0.0/12` | Services |
| `192.168.10.0/24` | Ingress-VIP `192.168.10.245`, Nodes |

Ohne diese Routen sieht der Proxy den Ingress nicht.

## Teil 3: Services im Dashboard

**Reverse Proxy → Services → Add Service**

### Empfohlen: eine HTTP-Service-Instanz pro App (Custom Domain)

Passt zu bestehenden Ingress-Hostnames (`search.f4mily.net`, `pdf.f4mily.net`, `*.cluster.f4mily.net`, …), sofern DNS bereits auf `netbird.f4mily.net` zeigt (z. B. `*.srv1`).

| Feld | Wert |
|------|------|
| Mode | **HTTP** |
| Domain | Custom: z. B. `search.f4mily.net` |
| Target type | **Host** (oder Subnet + IP) |
| Target | `192.168.10.245` |
| Protocol / Port | **HTTPS** / **443** |
| Settings | **Pass Host Header** = an (Ingress braucht den öffentlichen Hostnamen) |
| Settings | **Rewrite Redirects** = an (verhindert Redirects auf interne URLs) |
| Authentication | SSO / Passwort / PIN nach Bedarf (öffentliche URLs sonst warnung im UI) |

Wiederhole für jede App, die von extern erreichbar sein soll.

### Alternative: Cluster-Domain unter `proxy.f4mily.net`

| Feld | Wert |
|------|------|
| Subdomain | z. B. `search` |
| Base domain | `proxy.f4mily.net` (Cluster-Badge im UI) |
| Target | wie oben |

Erreichbar dann als `https://search.proxy.f4mily.net` — ohne extra CNAME pro App, sofern `*.proxy` DNS gesetzt ist.

### Path-basiert (eine URL, mehrere Backends)

Mehrere Targets mit unterschiedlichen **Path**-Präfixen (`/api`, `/`) — nur sinnvoll, wenn die Apps Pfade unter einer Domain teilen.

## Netbird Networks (Pflicht für Cluster-Ziele)

Eine **Network Resource** (`k8s-ingress` / `192.168.10.245/32`) allein reicht nicht. Du brauchst zusätzlich:

### 1. Network `k8s-ingress`

| Einstellung | Wert |
|-------------|------|
| Resource | `192.168.10.245/32` (oder `192.168.10.0/24`) |
| Resource-Gruppe | z. B. `k8s-ingress` |
| **Routing Peers** | Gruppe mit allen K8s-Netbird-Peers (`talos-cp1` …) |
| Masquerade | **An** (Standard) |

### 2. Access Control (häufigster Fehler)

Ohne Policy ist Traffic **deny-by-default** — der Reverse Proxy erreicht den Ingress nicht.

| Policy | Source | Destination | Ports |
|--------|--------|-------------|-------|
| Proxy → Ingress | Gruppe **`reverse-proxy`** (Peer `netbird-proxy`) | Gruppe **`k8s-ingress`** (Resource) | TCP **443** (optional 80) |
| Optional LAN/VPN | Deine Client-Gruppe | `k8s-ingress` | TCP 443 |

Der **netbird-proxy**-Container ist ein eigener Peer — er muss in der Source-Gruppe der Forward-Policy stehen, nicht nur dein Laptop.

### 3. Reverse-Proxy-Service (z. B. `audible.f4mily.net`)

| Feld | Wert |
|------|------|
| Target | Resource **Host** `192.168.10.245` oder Subnet + IP |
| Protocol / Port | **HTTPS** / **443** |
| Pass Host Header | **An** |
| Rewrite Redirects | **An** |
| Path (Audiobookshelf) | optional `/audiobookshelf` — Ingress hat `app-root` auf `/`, beides möglich |

Status im UI: `tunnel_not_created` → Routing Peers / Access Policy prüfen; `certificate_failed` → DNS.

### 4. DNS

Öffentlich muss `audible.f4mily.net` auf den **Netbird-Host** zeigen (CNAME `netbird.f4mily.net`), **nicht** auf `192.168.10.245`. Lokal bleibt AdGuard auf die VIP (Terraform: public CNAME + lokales A).

## Beispiel-Checkliste

- [ ] `netbird-proxy` läuft, Status im Dashboard: Proxy-Instanz **connected**
- [ ] Traefik TCP-Router TLS passthrough → Proxy `:8443`
- [ ] K8s: `kubectl get pods -n netbird` → 3/3 Ready
- [ ] Network `k8s-ingress` mit Routing Peers (K8s-Gruppe) + Masquerade
- [ ] Access Policy: **`reverse-proxy` → `k8s-ingress`**, TCP 443
- [ ] Öffentliches DNS `audible` → `netbird.f4mily.net`
- [ ] Service `audible.f4mily.net` → Target `192.168.10.245:443`, Status **active**
- [ ] Test von Mobilfunk ohne VPN: `https://audible.f4mily.net`

## Hinweise

- **Rosenpass**: Reverse Proxy funktioniert derzeit nicht mit Rosenpass.
- **Backends** (Nextcloud, Jellyfin, …): ggf. „trusted proxies“ / `trusted_domains` für Netbird-IP-Bereiche — siehe [Service configuration](https://docs.netbird.io/manage/reverse-proxy/service-configuration).
- **L4** (SSH, DB): separater Modus TCP/TLS; extra Ports in `docker-compose` freigeben — siehe [L4 ports](https://docs.netbird.io/selfhosted/migration/enable-reverse-proxy#exposing-l4-ports).
- Schnelltest ohne Dashboard: `netbird expose` auf einem Peer (CLI) — eher für temporäre Freigaben.

## Links

- [Reverse Proxy Docs](https://docs.netbird.io/manage/reverse-proxy)
- [Cluster-Routing-Peers](netbird-cluster-access.md)
- [External Traefik Setup](https://docs.netbird.io/selfhosted/external-reverse-proxy)
