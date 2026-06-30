# Automatic Talos OS Upgrades via System Upgrade Controller

**Date**: 2026-06-18
**Severity**: high
**Affected**: cluster-wide (all control-plane nodes; Talos OS upgrades)
**Status**: resolved

## What Went Wrong

Automatic Talos OS upgrades — Renovate bumps the version in
`infrastructure/overlays/main/system-upgrade-controller/talos-plan.yaml`, and the
System Upgrade Controller (SUC) runs `talosctl upgrade` per node — silently failed.
After Renovate bumped Talos to v1.13.4 the SUC upgrade job failed, cordoned the
first node, and left the cluster stuck: every node still on the old version, the
Plan stuck `applying: [...]`.

The plan ran `talosctl upgrade --insecure` over the host apid Unix socket, assuming
that needed no credentials. It does not work on running nodes — and fixing it
surfaced **three** more non-obvious failures, each hidden behind the previous one.

## Why It Failed

The upgrade invocation was wrong in four ways:

1. **`--insecure`** uses Talos's *maintenance-mode* API, which only exists pre-boot
   (during install). On a running node it never responds → job fails, node left
   cordoned.
2. After switching to mTLS auth, talosctl errored **`nodes are not set`**: the
   shared talosconfig has `endpoints` but no `nodes`, and authenticated mode (unlike
   `--insecure`) needs an explicit target node.
3. With `-n` added but the **Unix-socket endpoint**, the TLS handshake failed:
   `x509: certificate is valid for talos-cp3, not localhost`. Over the socket
   talosctl verifies the apid *serving* cert against `localhost`, but the cert is
   issued for the node hostname/IP. (`--insecure` had skipped this check.)
4. **`exclusive: true`** on the Plan adds a *required* pod-anti-affinity
   (`upgrade.cattle.io/exclusive`, topologyKey hostname). The **last** node to
   upgrade is the one running `system-upgrade-controller`; its upgrade job cannot
   schedule there, and that job is exactly what would drain/relocate the controller
   → circular deadlock. cp1 hung until the controller pod was manually deleted.

Two environmental gotchas compounded it:

- **iSCSI multi-attach churn**: each node reboot disrupts the CNPG postgres replicas
  there (truenas-iscsi RWO PVCs). Clusters briefly drop to 2/3 and the drain of the
  *next* node blocks on their PodDisruptionBudgets (`allowed=0`). Self-heals in
  ~2-3 min as volumes re-attach — wait, do not force-evict.
- The talosconfig is **regenerated on every cluster deployment**, so it cannot live
  in Git; it is provisioned by OpenTofu (below).

## The Correct Approach

**1. talosconfig secret, provisioned by Terraform (not committed).**
OpenTofu creates the mTLS client config into the `system-upgrade` namespace:
`homelab-infrastructure/talos/envs/homelab-kube/system-upgrade.tf` →
`kubernetes_secret_v1.talosconfig` (key `talosconfig`). It must exist *before* the
Plan reconciles.

**2. SUC Plan upgrade invocation** (`talos-plan.yaml`):

```yaml
spec:
  concurrency: 1
  # NO exclusive: true  — see point 4
  cordon: true
  secrets:
    - name: talosconfig
      path: /var/run/secrets/talos.dev
  upgrade:
    image: ghcr.io/siderolabs/talosctl:vX.Y.Z
    envs:
      - name: NODE_IP
        valueFrom:
          fieldRef:
            fieldPath: status.hostIP   # job is hostNetwork=true on the target node
    command: [/talosctl]
    args:
      - --talosconfig=/var/run/secrets/talos.dev/talosconfig
      - -e
      - $(NODE_IP)        # node IP over TCP — cert IS valid for it (NOT the unix socket)
      - -n
      - $(NODE_IP)        # authenticated mode needs an explicit node
      - upgrade
      - --image=factory.talos.dev/nocloud-installer/<schematic>:$(SYSTEM_UPGRADE_PLAN_LATEST_VERSION)
      - --drain=false     # SUC drains via its own init container
      - --wait=false
      - --timeout=15m
```

Verify auth/endpoint locally before trusting any arg change — each wrong flag only
reveals the next error:

```bash
talosctl --talosconfig <cfg> -e <node-ip> -n <node-ip> version   # must return a Server Tag
```

**3. Do not set `exclusive: true`** — redundant for a single plan with
`concurrency: 1`, and it causes the last-node deadlock. If you ever still hit it,
the manual unblock is to move the controller off the stuck node:

```bash
kubectl -n system-upgrade delete pod <system-upgrade-controller-pod>
```

**4. Keep versions in sync** between this repo (`talos-plan.yaml` `version` +
installer image) and Terraform (`cluster.auto.tfvars` `talos_version` + schematic).
Note: SUC's `talosctl upgrade --image` does **not** rewrite the node's machineconfig
`install.image`, so Terraform and the running version can legitimately diverge until
the next `tofu apply`.

## Prevention

- When editing the upgrade `args`, first run `talosctl ... version` over the exact
  same endpoint + auth. Do not assume; each wrong flag is hidden behind the previous.
- `main` is branch-protected: Talos plan changes go via **PR**, and Terraform cannot
  push Flux bootstrap manifests (`flux_bootstrap_git` carries `ignore_changes`).
- `tofu plan/apply` runs `data.talos_cluster_health`, which **fails while any node is
  cordoned**. During an upgrade window: pause SUC
  (`kubectl -n system-upgrade scale deploy system-upgrade-controller --replicas=0`) +
  `kubectl uncordon <node>` before running tofu.
- Expect CNPG to dip to 2/3 after each node reboot — wait for self-heal.

## Update 2026-06-30 — three more stall modes (v1.13.4 → v1.13.5)

The auth fixes above were necessary but not sufficient. The v1.13.5 rollout exposed
three further blockers, each of which silently stalls the autonomous upgrade.

**5. The SUC controller blocks the upgrade of its OWN node (anti-affinity self-block).**
The per-node upgrade job pods *and* the controller pod both carry the label
`app.kubernetes.io/name=system-upgrade-controller`. The controller Deployment has a
`required` podAntiAffinity on that label (topologyKey `kubernetes.io/hostname`), so the
upgrade job pod for the node currently hosting the controller can **never** schedule
there:

```
FailedScheduling: 1 node(s) didn't satisfy existing pods anti-affinity rules,
                  2 node(s) didn't match Pod's node affinity/selector
```

That node never cordons/drains and the Plan sits `applying: [<that-node>]`. **Fix:**
relocate the controller onto an *already-upgraded* node and leave it there for the rest
of the rollout — it then blocks nothing:

```bash
# cordon the other free nodes so the controller can only land on the done node, then:
kubectl -n system-upgrade delete pod -l app.kubernetes.io/name=system-upgrade-controller
# uncordon afterwards
```

Caveat: that label selector **also matches the live upgrade job pod**. A
`--field-selector status.phase!=Running` to "only kill the broken controller" can
delete a mid-reboot upgrade pod too — harmless (the Job re-reconciles), but don't be
surprised.

**6. The controller image was pinned to a tag that was never released.**
`infrastructure/base/system-upgrade-controller/kustomization.yaml` had
`images.newTag: v0.20.0`. That tag does not exist — upstream shipped only
`v0.20.0-rc.1`; latest stable (and the manifest `?ref=`) is `v0.19.2`.
`docker.io/rancher/system-upgrade-controller:v0.20.0` returns **NotFound**. The
controller only kept running off **cached containerd layers** on the nodes that had
pulled it earlier; the moment its pod rescheduled onto an uncached / freshly-rebooted
node it hit `ErrImagePull (NotFound)` — stalling the rollout *at the orchestrator
itself*. Fixed to `v0.19.2` (PR #358). **Rule: `images.newTag` must equal the manifest
`?ref=` and be a published stable tag** — a `renovate:` hint + comment now guards it.

**7. The CNPG operator FREEZES while a primary sits on a cordoned node.**
When SUC cordons a node whose CNPG cluster has its primary there, the operator logs:

```
Primary is running on an unschedulable node, will try switching over
Current primary is running on unschedulable node and something is already in progress
```

…and **stops all other reconciliation** — including re-bootstrapping a replica you just
deleted. So the documented "delete the broken replica's PVC, let CNPG re-clone via
`pg_basebackup`" recovery does *nothing* until the node is uncordoned. Chicken-and-egg
with the stuck upgrade cordon. **Always pause SUC and `uncordon` the node before doing
any CNPG replica repair.** Sequence that worked:

```bash
kubectl -n system-upgrade scale deploy system-upgrade-controller --replicas=0
kubectl uncordon <node>                       # unfreezes the CNPG operator
# now delete the broken replica's pod+PVC → CNPG re-bootstraps it cleanly
# once all clusters are healthy, scale the controller back to 1
```

Underlying trigger this time: a TrueNAS iSCSI blip left the immich replicas' WAL
diverged with a zeroed record, so `pg_rewind` could never rejoin
(`invalid record length ... expected at least 24, got 0`) → permanent CrashLoop, no
failover target, primary PDB `allowed=0` → drain blocked → `jobActiveDeadlineSecs`
(`DeadlineExceeded`). The single-instance `dawarich-postgres` was a second, structural
drain blocker — a 1-instance cluster has no switchover target, so its primary PDB blocks
every drain of its node. Scaled to `instances: 2` with `required` pod-anti-affinity
(PR #355). Same pattern as `immich-postgres`; both keep dedicated clusters because they
need extensions the shared `homelab-postgres` (vanilla `postgresql:18.4`) does not ship
(`postgis` / vector `vchord`).

## Related

- PRs: #268 (talosconfig mTLS auth), #269 (`-n $(NODE_IP)`),
  #270 (`-e $(NODE_IP)` over TCP), #271 (drop `exclusive: true`),
  #355 (dawarich-postgres `instances: 2`), #358 (SUC image pin `v0.20.0` → `v0.19.2`)
- Terraform module `kreativmonkey/terraform-module` **v0.2.0** (per-node `storage_id`,
  `etcd_advertised_subnets`)
- `infrastructure/overlays/main/system-upgrade-controller/talos-plan.yaml`
- `homelab-infrastructure/talos/envs/homelab-kube/system-upgrade.tf`
- [democratic-csi-pvc-resize-permission-denied.md](democratic-csi-pvc-resize-permission-denied.md) — related Talos + iSCSI behaviour
