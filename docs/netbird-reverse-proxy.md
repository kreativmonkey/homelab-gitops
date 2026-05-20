# Netbird Reverse Proxy — Homelab-Services ohne Port-Forwarding

Mit dem [Netbird Reverse Proxy](https://docs.netbird.io/manage/reverse-proxy) (ab v0.65) erreichst du interne Dienste von außen über HTTPS. Der Traffic läuft über die Netbird-Infrastruktur (`netbird.f4mily.net`); am Router musst du **keine** zusätzlichen Ports für einzelne Apps öffnen.

Offizielle Referenzen: [Reverse Proxy](https://docs.netbird.io/manage/reverse-proxy), [Troubleshooting](https://docs.netbird.io/manage/reverse-proxy/troubleshooting), [Access Logs](https://docs.netbird.io/manage/reverse-proxy/access-logs).

## Architektur (Homelab)

```mermaid
flowchart LR
  Internet[Client]
  Proxy[netbird-proxy]
  Mesh[WireGuard Mesh]
  K8sPeer[K8s Peer talos-cp1]
  Ingress[NGINX :443 / VIP 192.168.10.245]
  App[Audiobookshelf]

  Internet --> Proxy
  Proxy --> Mesh
  Mesh --> K8sPeer
  K8sPeer --> Ingress
  Ingress --> App
```

Der **Reverse Proxy** baut den Tunnel zum Ziel über das Management — es gibt **keine** separate Dashboard-Policy mit Source-Gruppe `netbird-proxy`. Das war eine Fehleinschätzung in einer früheren Doku-Version.

## 502 „request failed“ — typische Ursache im Talos-Cluster

Proxy Events mit **Status 502** und **Reason `request failed`** bedeuten: der Proxy hat die Anfrage angenommen, aber das **Backend** (dein Ziel) antwortet nicht — siehe [Access Logs](https://docs.netbird.io/manage/reverse-proxy/access-logs) (5xx = Backend/Connectivity).

### Issue 0: Protocol „HTTPS“ im HTTP-Service (sehr häufig, nicht das Zertifikat)

Im Dashboard bedeutet **Protocol HTTPS / Port 443**: Der Netbird-Proxy baut **zum Backend** eine TLS-Verbindung auf — nicht „öffentlich wie im LAN über HTTPS“.

| Was du siehst | Was passiert |
|---------------|--------------|
| Browser → `https://audible.f4mily.net` | TLS wird am **Netbird-Edge** beendet (öffentlich weiterhin HTTPS) |
| Proxy → Backend **HTTPS :443** | Zweiter TLS-Handshake zum Ingress/Peer — hier scheitert es oft |

**„Skip TLS Verification“ hilft hier meist nicht:** Das betrifft nur die Zertifikatsprüfung. Bekanntes Problem ist der **Upstream-TLS-Handshake** (fehlendes SNI/Origin-Name) — [netbirdio/netbird#5461](https://github.com/netbirdio/netbird/issues/5461). Ein gültiges Let’s-Encrypt-Zertifikat auf dem Ingress ändert daran nichts.

**Empfohlen (HTTP-Service, wie von Netbird vorgesehen):**

| Feld | Wert |
|------|------|
| Target type | **Peer** (`talos-cp*`) |
| Protocol / Port | **HTTP** / **80** |
| Pass Host Header | **An** |
| Rewrite Redirects | **An** |
| Path | **leer** |

Der Client nutzt weiterhin **HTTPS** zur öffentlichen URL; nur die letzte Strecke (Proxy → NGINX auf dem Peer) ist HTTP — üblich hinter TLS-terminierenden Proxies.

**Wenn du echtes TLS bis zum Ingress brauchst:** L4-Service-Modus **TLS** (Passthrough, SNI `audible.f4mily.net`) auf Peer-Port **443** — nicht HTTP-Service mit Protocol HTTPS.

**Heimnetz-Vergleich:** `https://192.168.10.245` im LAN = Browser spricht **direkt** mit NGINX. Über Netbird HTTP-Service + HTTPS-Backend = **zwei** TLS-Hops; das ist nicht dasselbe und ist der Grund für 502 bei Protocol HTTPS.

### Issue 1: Ziel-IP = Routing-Peer selbst (sehr häufig hier)

Wenn der **Netbird-Client auf denselben Nodes** läuft wie der Ingress (DaemonSet + `hostNetwork`) und du als Reverse-Proxy-Ziel eine **Network Resource** (`Host`/`Subnet` → `192.168.10.245`) nutzt, trifft genau [Issue 1 in der offiziellen Doku](https://docs.netbird.io/manage/reverse-proxy/troubleshooting#issue-1-502-errors-when-routing-peer-forwards-to-its-own-ip) zu:

- Der Routing Peer soll Subnet-Traffic **an andere Hosts** weiterleiten.
- Leitet er auf eine **eigene** IP (hier die Ingress-VIP auf dem Node), fehlen die ACL-Regeln für „self-targeted“ Traffic → Timeout → **502**.

**Lösung für `audible.f4mily.net` und andere Cluster-Ingress-Hosts (K8s: Netbird + Ingress auf demselben Node):**

| Feld | Wert |
|------|------|
| Target type | **Peer** (nicht Host/Subnet/Network Resource) |
| Peer | z. B. `talos-cp1` (Node mit Ingress; im Dashboard „Connected“) |
| Protocol / Port | **HTTP** / **80** (siehe Issue 0 — nicht HTTPS/443) |
| Pass Host Header | **An** |
| Rewrite Redirects | **An** |
| Path | **leer** (nicht `/audiobookshelf` anhängen) |
| Domain | Custom: z. B. `audible.f4mily.net` |

**Empfohlen:** Target **Peer** = K8s-Control-Plane (`talos-cp*`), damit der Cluster später ohne `srv1` auskommt. GitOps: `NB_ENABLE_LOCAL_FORWARDING=true`.

**Nur mit Routing Peer auf anderem Host** (z. B. `srv1`): Target **Host** `192.168.10.245`, **HTTP 80** oder L4-TLS-Passthrough **443** — nicht HTTP-Service + HTTPS-Backend.

Bei **Host** `192.168.10.245` und Routing-Peer = derselbe K8s-Node → zusätzlich Issue 1 (Timeout/502), unabhängig von HTTP/HTTPS.

GitOps setzt `NB_ENABLE_LOCAL_FORWARDING=true`, damit Tunnel-Traffic die lokalen Listener (NGINX `hostNetwork`) erreicht.

**Alternative:** Netbird-Client nur auf **`srv1`** (Routing Peer), Ziel **Host** `192.168.10.245` — dann kein Peer+Ingress auf einem Node und `Host`/`Subnet` funktionieren wieder.

### Weitere 502-Ursachen (Checkliste)

1. Service-Status im Dashboard **active** (nicht `tunnel_not_created`).
2. Vom Routing Peer lokal testen: `curl -skI -H 'Host: audible.f4mily.net' https://192.168.10.245/`
3. Backend bindet nicht nur `127.0.0.1` — Ingress ist OK (`hostNetwork`).
4. Audiobookshelf: Protocol **HTTP 80**, Path leer, Host `audible.f4mily.net` (nicht HTTPS-Backend).
5. Self-hosted Debug: `NB_PROXY_DEBUG_ENDPOINT=true` → `netbird-proxy debug ping <account-id> 192.168.10.245 443`

## Netbird-Server (Docker)

[Enable Reverse Proxy](https://docs.netbird.io/selfhosted/migration/enable-reverse-proxy): `netbirdio/reverse-proxy`, Traefik **TLS passthrough**, `NB_PROXY_DOMAIN`, Token, DNS `proxy` / `*.proxy` → `netbird.f4mily.net`.

## Kubernetes (GitOps)

- Namespace `netbird`: **privileged** Pod-Security (`hostNetwork`, NET_ADMIN).
- DaemonSet `netbird`: Client **≥ 0.71**.
- **Network Routes** im Dashboard (Peers der Setup-Key-Gruppe):

| Netz | Zweck |
|------|--------|
| `10.244.0.0/16` | Pods |
| `10.96.0.0/12` | Services |
| `192.168.10.0/24` | Ingress-VIP `192.168.10.245`, Nodes |

Ohne diese Routen sieht der Proxy den Ingress nicht.

- Optional **Networks** `k8s-ingress` für VPN-Zugriff auf `192.168.10.0/24` (Mesh-Clients) — Routing Peers = K8s-Peer-Gruppe, Masquerade an, Policies Source = deine Client-Gruppen → Resource-Gruppe.
- **Reverse Proxy** zum Ingress: Target-Typ **Peer**, nicht die Network Resource.

## Services im Dashboard

**Reverse Proxy → Services → Add Service**

### Empfohlen: eine HTTP-Service-Instanz pro App (Custom Domain)

Passt zu bestehenden Ingress-Hostnames (`audible.f4mily.net`, `search.f4mily.net`, `*.cluster.f4mily.net`, …), sofern DNS öffentlich auf Netbird zeigt (z. B. CNAME → `netbird.f4mily.net`).

| Feld | Wert |
|------|------|
| Mode | **HTTP** |
| Domain | Custom: z. B. `search.f4mily.net` |
| Target type | **Peer** (K8s-Ingress auf demselben Node) **oder** **Host** `192.168.10.245` (Routing Peer z. B. `srv1`) |
| Protocol / Port | **HTTP** / **80** (nicht HTTPS/443 — Issue 0) |
| Path | **leer** |
| Settings | **Pass Host Header** = an |
| Settings | **Rewrite Redirects** = an |
| Authentication | SSO / Passwort / PIN nach Bedarf |

### Alternative: Cluster-Domain unter `proxy.f4mily.net`

Netbird-verwaltete Subdomain statt Custom Domain — siehe [Reverse Proxy](https://docs.netbird.io/manage/reverse-proxy).

## DNS `audible.f4mily.net`

- **Öffentlich:** CNAME → `netbird.f4mily.net` (Reverse Proxy-TLS).
- **Lokal (AdGuard):** A → `192.168.10.245` (direkt im LAN).

Terraform: `homelab-infrastructure/dns/servers.tf` (`audible` public CNAME).

## VIP `192.168.10.245` im Cluster

Über **Networks** (IP-Routing, kein DNS für „245“):

| Komponente | Zweck |
|------------|--------|
| Resource `192.168.10.245/32` oder `192.168.10.0/24` | Ingress-VIP |
| Routing Peers | K8s-Netbird-Nodes und/oder andere Server im LAN (`srv1`, …) |
| Reverse Proxy | Ziel **Host** `192.168.10.245` + Routing Peer auf **anderem** Host |

Der K8s-DaemonSet kann als Routing Peer die VIP im Mesh bekannt machen; für den öffentlichen Reverse Proxy reicht oft ein Peer außerhalb der CP-Nodes.

## 404 / 502 bei `audible.f4mily.net`

| Symptom | Ursache | Fix |
|---------|---------|-----|
| **502** bei Protocol HTTPS | Upstream-TLS zum Ingress kaputt (Issue 0), nicht das LE-Zertifikat | **HTTP 80** + Pass Host Header, oder L4 TLS-Passthrough |
| **502** (Timeout) | Host `192.168.10.245` + Peer auf demselben Node (Issue 1) | Target **Peer**, nicht Host/Subnet |
| **404** (NGINX) | Falscher Ingress-Pfad oder Host-Header fehlt | Path im Proxy **leer**, **Pass Host Header** an |
| **Cannot GET /audiobookshelf/** | Pfad im Netbird-Proxy gesetzt — doppelt/inkorrekt | Path-Feld **leer** lassen; URL `https://audible.f4mily.net/` (App leitet intern um) |

### Netbird-Dashboard (`audible.f4mily.net`) — wie andere Homelab-Apps

| Feld | Wert |
|------|------|
| Target type | **Peer** (`talos-cp1` o. ä.) |
| Protocol / Port | **HTTP** / **80** |
| Path | **leer** |
| Pass Host Header | **An** |
| Rewrite Redirects | **An** |

### GitOps (Audiobookshelf)

- Ingress wie Jellyfin: `ssl-redirect: true`, Pfade `/` und `/audiobookshelf` (App v2.18+)
- Heimnetz-Test: `curl -skI -H 'Host: audible.f4mily.net' https://192.168.10.245/`

## Beispiel-Checkliste `audible`

- [ ] `netbird-proxy` läuft, Status im Dashboard: Proxy-Instanz **connected**
- [ ] Traefik TCP-Router TLS passthrough → Proxy `:8443`
- [ ] K8s: `kubectl get pods -n netbird` → Ready
- [ ] Network Routes aktiv
- [ ] Reverse-Proxy: **Peer** `talos-cp*`, **HTTP 80**, Path **leer**, Host Header + Rewrite an (kein HTTPS-Backend)
- [ ] Netbird-Pods mit `NB_ENABLE_LOCAL_FORWARDING=true` (Flux)
- [ ] Service-Status **active**, Proxy Events: kein 502
- [ ] Öffentlich: `dig audible.f4mily.net` → Netbird-Host, nicht `192.168.10.245`
- [ ] `https://audible.f4mily.net` von außen (ohne VPN)

## Hinweise

- **Rosenpass**: Reverse Proxy funktioniert derzeit nicht mit Rosenpass.
- **Backends** (Nextcloud, Jellyfin, …): ggf. „trusted proxies“ / `trusted_domains` für Netbird-IP-Bereiche — siehe [Service configuration](https://docs.netbird.io/manage/reverse-proxy/service-configuration).
- **L4** (SSH, DB): separater Modus TCP/TLS; extra Ports in `docker-compose` freigeben — siehe [L4 ports](https://docs.netbird.io/selfhosted/migration/enable-reverse-proxy#exposing-l4-ports).
- Schnelltest ohne Dashboard: `netbird expose` auf einem Peer (CLI) — eher für temporäre Freigaben.

## Links

- [Troubleshooting (Issue 1)](https://docs.netbird.io/manage/reverse-proxy/troubleshooting#issue-1-502-errors-when-routing-peer-forwards-to-its-own-ip)
- [Backend trusted proxies `100.64.0.0/10`](https://docs.netbird.io/manage/reverse-proxy/service-configuration)
- [Cluster-Routing-Peers](netbird-cluster-access.md)
