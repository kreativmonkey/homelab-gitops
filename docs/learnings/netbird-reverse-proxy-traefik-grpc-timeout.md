# NetBird Reverse Proxy: 404/502 from Traefik gRPC Stream Timeout

**Date**: 2026-06-14
**Severity**: high
**Affected**: infrastructure (external access path — NetBird reverse proxy on the VPS, *not* the cluster)
**Status**: resolved

## What Went Wrong

All cluster applications published through the **NetBird reverse proxy** (`netbirdio/reverse-proxy` on the Hetzner VPS) suddenly returned **`404 page not found`** or **`502 Bad Gateway`** for every domain (`git.f4mily.net`, `status.cluster.f4mily.net`, `teslamate.f4mily.net`, …).

The timing coincided with the TrueNAS iSCSI outage / a flurry of GitOps work, so the cluster was the prime suspect. **It was not.** The cluster, ingress-nginx, and all apps were healthy the whole time:

```bash
# In-cluster test against the ingress ClusterIP — all 200, so cluster + apps are fine
kubectl run t --rm -i --image=curlimages/curl -- sh -c \
  'for h in git.f4mily.net status.cluster.f4mily.net; do
     curl -s -o /dev/null -w "$h %{http_code}\n" -H "Host: $h" http://<ingress-clusterip>/; done'
# git.f4mily.net 200 / status.cluster.f4mily.net 200

# Even the NetBird DaemonSet pods (hostNetwork) reached the ingress and got 200.
```

The fault was entirely in the **VPS-side NetBird control plane**, behind `traefik_local`.

## Why It Failed

NetBird's management peer-sync uses a **long-lived gRPC long-poll**: `POST /management.ManagementService/Job`. The Traefik instance in front of the NetBird server cut that stream after exactly 60 s:

```
# traefik_local access log
"POST /management.ManagementService/Job HTTP/2.0" 504 ... "h2c://172.18.0.4:80" 60000ms
```

Short RPCs (`GetServerKey`, `SignalExchange/Send`) returned `200`, so the stack *looked* partially up — but without a stable `Job` stream, **no peer ever finished syncing network state**. The `netbird-proxy` (itself a NetBird peer) could therefore never establish WireGuard/ICE tunnels to the cluster nodes:

```
# netbird-proxy log
disconnected from the Signal service but will retry silently
[peer: …] ICE Agent is not initialized yet      # for many peers
```

No tunnel to the cluster peers ⇒ no route to the apps ⇒ **404** (no route) / **502** (dead upstream).

**Trigger:** the NetBird containers run on **unpinned `:latest`** tags. A restart pulled a newer `netbird-server` whose management sync uses this long-poll `Job` model, which trips a **pre-existing 60 s Traefik responding-timeout** that the older streaming model never hit. `traefik_local` itself was unchanged. (The exact moment the image rolled forward was not pinned down — the mechanism is certain, the timestamp is inferred.)

## The Correct Approach

1. **Disable Traefik's responding read-timeout** so long-lived gRPC streams are not cut. On the `websecure` entrypoint of `traefik_local`:

   ```yaml
   entryPoints:
     websecure:
       address: ":443"
       transport:
         respondingTimeouts:
           readTimeout: 0      # 0 = unlimited (was effectively 60s)
   ```

   (CLI equivalent: `--entryPoints.websecure.transport.respondingTimeouts.readTimeout=0`)

2. **Restart `netbird-proxy` and `netbird-server` after the Traefik fix.** They do **not** self-heal from a multi-hour broken reconnect loop — a Traefik restart alone left the proxy stuck in `signal is not ready` + a flood of `TLS handshake error … missing server name`. A fresh start re-established cleanly:

   ```
   # netbird-proxy after restart against the fixed Traefik
   notified management about tunnel connection   # per domain: git/paperless/teslamate/…
   # TLS handshake errors: 0
   ```

3. **Verify end-to-end**, not just the logs:

   ```bash
   for h in status.cluster.f4mily.net git.f4mily.net teslamate.f4mily.net; do
     curl -s -o /dev/null -w "$h %{http_code}\n" "https://$h/"; done
   # all 200
   ```

## Prevention

- **Pin the NetBird images** (`netbird-server`, `reverse-proxy`, `dashboard`) — no `:latest`. Bump via Renovate so a protocol change like the `Job` long-poll is a reviewed, revertible event instead of a silent break on the next restart.
- **Traefik (or any proxy) in front of NetBird gRPC must not time out long-lived streams** — keep `respondingTimeouts.readTimeout: 0` on the entrypoint serving `/management.ManagementService/` and `/signalexchange.SignalExchange/`.
- **Diagnostic shortcut:** when NetBird peers report `Management/Signal: Connected` but tunnels never form (`ICE Agent is not initialized yet`), suspect the long-lived management/signal stream being cut by a proxy timeout. Look in the proxy access log for `504` with a round `~60000ms` duration on `/management.ManagementService/Job`.
- **Exonerate the cluster first:** `curl -H "Host: <app>" http://<ingress-clusterip>/` from inside the cluster. A `200` proves cluster + ingress + app are fine and the fault is upstream (NetBird/Traefik/DNS), saving hours of looking in the wrong place.

## Related

- [nextcloud-iscsi-emergency-readonly.md](nextcloud-iscsi-emergency-readonly.md) — same TrueNAS-outage window that prompted the restarts.
- NetBird stack lives on the Hetzner VPS (Dockhand env "VPS", `vps-hetzner.vpn.f4mily.net`), fronted by `traefik_local`. Not managed by this GitOps repo.
