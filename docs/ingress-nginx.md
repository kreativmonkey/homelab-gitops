# NGINX Ingress (homelab)

Homelab uses the **NGINX Ingress Controller** with `ingressClassName: nginx` and annotations prefixed with **`nginx.org/`**.

See also the ingress checklist in the workspace [`AGENTS.md`](../../AGENTS.md) (or `homelab-infrastructure/AGENTS.md`).

## WebSocket-enabled apps

| App | Service name | Notes |
|-----|--------------|--------|
| n8n | `n8n-app` | Editor push: `wss://…/rest/push` |
| Immich | `immich-server` | Upload / live features |
| TeslaMate | `teslamate`, `teslamate-grafana` | Phoenix / Grafana Live |

## Minimal WebSocket snippet

```yaml
metadata:
  annotations:
    nginx.org/websocket-services: "<backend-service-name>"
    nginx.org/proxy-read-timeout: "3600s"
    nginx.org/proxy-send-timeout: "3600s"
```

`websocket-services` must list the **Kubernetes Service** name, not the Ingress metadata name.
