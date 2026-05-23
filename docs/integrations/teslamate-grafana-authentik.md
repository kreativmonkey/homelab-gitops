# TeslaMate Grafana ↔ Authentik

OAuth for `teslamate-grafana` uses Authentik at `https://login.f4mily.net` (application slug **`tesla-grafana`**).

## GitOps

- Secret: `apps/base/teslamate/teslamate-grafana-oauth.secret.yaml` (`client-id`, `client-secret`)
- ConfigMap: `apps/base/teslamate/teslamate-grafana-config.configmap.yaml`
- Blueprint: `apps/base/authentik/blueprints/teslamate-grafana-oauth.configmap.yaml`

After first Flux reconcile, set the **Provider for TeslaMate Grafana** client secret in Authentik to match `teslamate-grafana-oauth` (same value as production if you migrated the OAuth app).

Redirect URI: `https://teslamate-grafana.cluster.f4mily.net/login/generic_oauth`

## MQTT (Home Assistant)

- In-cluster: `mosquitto.teslamate.svc:1883`
- LAN (production-like): `192.168.10.245:1883` via `mosquitto-external` Service

## DB migrations

NodePort `homelab-postgres-restore` → port **30433** on any control-plane node (see `infrastructure/overlays/main/database-clusters/postgres-restore-nodeport.yaml`).
