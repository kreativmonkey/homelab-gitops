# Netbird — Cluster-Zugriff

Der Homelab-Cluster tritt dem selbst gehosteten Netbird-Management unter
**https://netbird.f4mily.net** bei. Pro Node läuft ein Netbird-Client als
`DaemonSet` mit `hostNetwork` (Namespace `netbird`).

**Externe Erreichbarkeit ohne Port-Forwarding:** [netbird-reverse-proxy.md](netbird-reverse-proxy.md) — Reverse-Proxy-Feature auf dem Netbird-Server plus HTTP-Services im Dashboard (Ziel: Ingress `192.168.10.245:443`).

## GitOps

| Ressource | Beschreibung |
|-----------|--------------|
| `apps/base/netbird/daemonset.yaml` | Client auf jedem Node |
| `apps/base/netbird/netbird-setup.secret.yaml` | Setup-Key (SOPS) |

## Netbird Dashboard (manuell)

Nach dem ersten Peer-Join im Dashboard konfigurieren:

### 1. Setup-Key / Gruppe

Der Setup-Key sollte **reusable** und **ephemeral peers** nutzen. Weise Peers der Gruppe **`kubernetes-routers`** (oder deiner Wahl) zu.

### 2. Network Routes

Leite diese Netze über die Peer-Gruppe der Kubernetes-Router:

| Zielnetz | Zweck |
|----------|--------|
| `10.244.0.0/16` | Pod-CIDR |
| `10.96.0.0/12` | Service-CIDR |
| `192.168.10.0/24` | Node-LAN (API `192.168.10.245`, Ingress hostNetwork) |

Distribution: Gruppe deiner Netbird-Clients (z. B. alle verbundenen Geräte).

### 3. Access Control

Policy: Quelle = deine Client-Gruppe, Ziel = `kubernetes-routers` (oder breiter nach Bedarf).

## Erreichbarkeit

- **Kubernetes-API:** `https://192.168.10.245:6443` (über Route zum LAN)
- **Ingress-Apps:** `*.f4mily.net` / `*.cluster.f4mily.net` → DNS zeigt auf `192.168.10.245` (siehe `homelab-infrastructure/dns/servers.tf`)

## Prüfen

```bash
kubectl get pods -n netbird -o wide
kubectl logs -n netbird -l app=netbird --tail=20
```

Im Netbird-Dashboard sollten drei Peers (`talos-cp1` …) als Connected erscheinen.
