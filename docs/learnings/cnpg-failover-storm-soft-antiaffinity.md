# CNPG Failover Storm from Soft Pod Anti-Affinity on Node Drain

**Date**: 2026-06-21
**Severity**: high
**Affected**: cluster-wide (both CNPG clusters + every DB-backed app: Authentik, forgejo, nextcloud, teslamate, outline, …)
**Status**: resolved

## What Went Wrong

An autonomous Talos OS upgrade (System Upgrade Controller draining one node at a
time — see [talos-automatic-upgrade-suc-auth.md](talos-automatic-upgrade-suc-auth.md))
triggered a ~15-minute **CNPG failover storm**. When `talos-cp3` was cordoned and
drained, both `homelab-postgres` and `immich-postgres` cascaded through repeated
switchovers/restarts, and a replica was left WAL-ahead in a rewind loop. Every
DB-backed app lost its connection and restarted (Authentik, forgejo, nextcloud,
teslamate, outline, tandoor, …).

The clusters self-recovered (operator logged *"Cluster has become healthy"*), but
redundancy was degraded and one replica stayed stuck.

## Why It Failed

The drain of a single node took down **two of three** instances of each cluster at
once, because the instances were not spread across nodes:

1. **`podAntiAffinityType: preferred` (soft)** let the scheduler co-locate instances.
   Result: `talos-cp3` hosted **4 of 6** postgres instances — including **both
   primaries** — while `talos-cp1` hosted none. Draining cp3 evicted primary + replica
   of the same cluster simultaneously.
2. **`failoverDelay: 0`** (the default) triggered an immediate failover on the first
   blip instead of waiting out the transient drain.
3. The primary-PDB (`allowedDisruptions: 0`) forced a switchover before the primary
   could be evicted — fine in isolation, but with a second instance also on the
   draining node it turned into a cascade, and the old primary came back WAL-ahead.

A separate, pre-existing **timeline divergence** (an orphaned timeline-11 `.history`
in the barman S3 store while the cluster ran timeline 10, from an earlier split-brain)
meant the WAL-ahead replica could not cold-rejoin via `pg_rewind`/archive — it sat in
`waiting for WAL to become available` + `Refusing to restore future timeline history`.

## The Correct Approach

**Spread instances hard, one per node**, on both clusters
(`infrastructure/overlays/main/database-clusters/cluster.yaml` and
`.../immich-postgres/cluster.yaml`):

```yaml
spec:
  affinity:
    podAntiAffinityType: required   # was: preferred
  failoverDelay: 30                 # was: 0 (default)
```

With 3 instances / 3 nodes, `required` guarantees exactly one instance per node, so a
node drain only ever evicts **one** instance per cluster — a single clean switchover,
the other two stay up.

Applying this triggers a **one-time controlled rolling rebalance** (one replica per
cluster moves to the empty node, one at a time, PDB-respecting). It exposed the
pre-diverged replica, which could not rejoin. Re-clone a stuck replica fresh from the
primary (no data loss — it is a replica). The `kubectl cnpg` plugin was not installed,
so do it manually; CNPG re-provisions the instance (with a new ordinal) via
`pg_basebackup`:

```bash
kubectl -n cnpg-system delete pvc homelab-postgres-1 --wait=false
kubectl -n cnpg-system delete pod homelab-postgres-1 --wait=false
# CNPG creates job <cluster>-<N+1>-join → fresh clone from the primary on the live timeline
```

Then take a fresh base backup so the recovery baseline is on the clean timeline:

```bash
kubectl apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: homelab-postgres-clean-tl10-20260621, namespace: cnpg-system }
spec:
  cluster: { name: homelab-postgres }
  method: barmanObjectStore
  target: prefer-standby
EOF
```

## Prevention

- **Always set `podAntiAffinityType: required` for new CNPG clusters** in this repo —
  the CNPG default `preferred` does not guarantee spreading and silently lets the
  primary + a replica share a node.
- This keeps **autonomous Talos/SUC upgrades safe with no manual intervention**: the
  primary-PDB (`allowedDisruptions: 0`) makes CNPG switch the primary off the draining
  node before eviction, well within the SUC drain timeout (`600s`); `force: true` on
  the SUC drain does **not** bypass PDBs.
- Caveat of `required` on a 3-node / 3-instance cluster: while a node is down/cordoned
  the third instance stays `Pending` (2/3, still HA) until the node returns — expected
  and safe.
- A diverged replica that will not rejoin (`Refusing to restore future timeline` /
  `waiting for WAL`) is re-cloned, not repaired — delete its PVC + pod and let CNPG
  re-`pg_basebackup` from the primary.

## Related

- [talos-automatic-upgrade-suc-auth.md](talos-automatic-upgrade-suc-auth.md) — the node-drain trigger
- PR #298 — required anti-affinity + `failoverDelay` on both clusters
- `infrastructure/overlays/main/database-clusters/cluster.yaml`, `.../immich-postgres/cluster.yaml`
- Lingering: an orphaned timeline-11 `.history` remains in the barman S3 store
  (`s3://cnpg-backups/homelab-postgres`); dormant after the re-clone + fresh base
  backup, optional careful object-store cleanup pending.
