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

### 3. Access Control (Networks, optional für VPN)

Für **direkten Mesh-Zugriff** (Laptop → Cluster): Policies von deiner Client-Gruppe zur Resource-Gruppe `k8s-ingress`.

Der **Reverse Proxy** nutzt dafür **keine** eigene Source-Gruppe `netbird-proxy` — der Tunnel zum Ziel wird über das Management beim Service angelegt.

**Wichtig:** Reverse Proxy zum Ingress auf denselben K8s-Nodes → Target-Typ **Peer**, nicht Network Resource `192.168.10.245` (sonst 502). Siehe [netbird-reverse-proxy.md](netbird-reverse-proxy.md#502-request-failed--typische-ursache-im-talos-cluster).

## Erreichbarkeit

- **Kubernetes-API:** `https://192.168.10.245:6443` (über Route zum LAN)
- **Ingress-Apps:** `*.f4mily.net` / `*.cluster.f4mily.net` → DNS zeigt auf `192.168.10.245` (siehe `homelab-infrastructure/dns/servers.tf`)

## Kubelet-Node-IP (100.96.x.x vs. LAN)

Netbird legt auf dem Host eine **100.96.0.0/16**-Adresse an. Ohne Filter wählt der
Kubelet diese als `InternalIP` — dann schlagen **metrics-server**, `kubectl exec`,
`port-forward` und Scrapes fehl (`no route to host` auf `:10250`), weil die
Control-Plane die Mesh-IP statt `192.168.10.41`–`.43` nutzt.

**Fix (Talos):** `machine.kubelet.nodeIP.validSubnets: [192.168.10.0/24]` in
`homelab-infrastructure/talos/main.tf` (und per `talosctl patch machineconfig` auf
bestehenden Nodes). Netbird-Mesh bleibt unverändert; nur die bei Kubernetes
gemeldete Node-Adresse ist die LAN-IP.

```bash
kubectl get nodes -o wide   # INTERNAL-IP sollte 192.168.10.x sein, nicht 100.96.x.x
```

## Prüfen

```bash
kubectl get pods -n netbird -o wide
kubectl logs -n netbird -l app=netbird --tail=20
```

Im Netbird-Dashboard sollten drei Peers (`talos-cp1` …) als Connected erscheinen.
