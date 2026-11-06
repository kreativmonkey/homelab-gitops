# SCST iSCSI transfer-size canary

## What went wrong

`vmstorage-1` on `talos-cp3` experienced prolonged I/O stalls on a TrueNAS
iSCSI volume. A bounded 64 MiB direct-I/O write at the 8192 KiB queue limit
stalled; after the limit was temporarily reduced to 4096 KiB, the same-sized
write and fsync completed in 0.161 seconds with a matching checksum. This is
one successful canary, not proof that request size caused the incident.

## Why it failed

The observed SCST allocation failure is consistent with larger iSCSI requests
exercising a different allocation path, but available evidence does not prove
that this caused the stalls. The paired test had one baseline timeout followed
by one successful capped write; it is a recovery signal, not a causal
benchmark. The source pinned by the TrueNAS release has a cached SGV path for up to
4 MiB and an uncached `kmalloc` branch above it ([SCST source](https://github.com/truenas/scst/blob/b962eef0607fbca601f2c76f72e88311bbe83e9e/scst/src/scst_mem.c#L991-L1008)).
That makes a 4 MiB cap a plausible mitigation to test, not a verified root cause.

## Correct approach

The Omni Talos template uses separate node-local `UdevRulesConfig` rules,
setting `queue/max_sectors_kb=4096` on block disk add/change events for exactly:

| Workload | Node | LUN WWID | Evidence |
| --- | --- | --- | --- |
| `vmstorage-1` | `talos-cp3` | `naa.6589cfc000000639f212aeb3d50f604d` | Original paired write test above |
| `vmstorage-0` | `talos-cp2` | `naa.6589cfc000000ac730d9232e23a9b285` | Correlated incident; capped runtime behavior still to verify |
| Forgejo | `talos-cp2` | `naa.6589cfc00000051ef2a67bed1f50c37d` | EIO on 2026-11-05, 20:04–20:10 UTC |
| Hister | `talos-cp2` | `naa.6589cfc000000c7af97dafcebacefb8a` | EIO on 2026-11-05, 19:42–19:48 UTC |
| Jellyfin | `talos-cp3` | `naa.6589cfc000000b4c73effd940a868d76` | EIO on 2026-11-05, 18:40 UTC |

On 2026-11-06, 02:14–02:30 UTC, vmstorage-0's volume (PV
`pvc-6c02ee25-a197-4994-8628-0a09a3b8419e`) had 180-second write
timeouts/EIO at 8192 KiB, a fatal fsync error and four container restarts.
TrueNAS concurrently reported `Allocation of sgv_pool_obj failed (size 8388608)`
and BUSY/QUEUE FULL. This motivates extending the bounded mitigation; it does
not add another paired test or prove the root cause. The three additional
LUNs above also had EIO at 8192 KiB in the 48-hour review, alongside SCST
8 MiB allocation failures. Their capped runtime behavior remains unverified.
Grafana showed latency only and is excluded. No rule covers unlisted LUNs or
follows a volume to another node.

Check each active value through the existing privileged democratic-CSI node
pod on the corresponding node, using its host `/sys` mount. Set `wwid` to the
matching table entry and find the block name first; do not assume `/dev/sdh`:

```sh
wwid=naa.6589cfc000000ac730d9232e23a9b285 # vmstorage-0 on cp2; select each table entry
for f in /sys/block/*/device/wwid; do
  if [ "$(cat "$f")" = "$wwid" ]; then
    name=${f#/sys/block/}
    name=${name%%/*}
    echo "$name: $(cat "/sys/block/$name/queue/max_sectors_kb") KiB"
  fi
done
```

Expect exactly one matching device per selected node and `4096`; verify
neighbor LUNs retain their previous values. After reconciliation, monitor node
write timeouts/EIO, vmstorage fsync failures/restarts and the TrueNAS SCST
journal across representative workload. Quiet samples alone do not establish
durable recovery. Review the rule and Omni desired config before rollout. Talos
1.14.5 reloads changed udev rules and retriggers device discovery live, without
a node reboot; verify the sysfs value after reconciliation. See the [Talos
UdevRulesConfig reference](https://docs.siderolabs.com/talos/v1.14/reference/configuration/runtime/udevrulesconfig)
and [Talos udev controller](https://github.com/siderolabs/talos/blob/v1.14.5/internal/app/machined/pkg/controllers/files/udev.go).

## Rollback

For each LUN independently, removing its rule alone does **not** restore the
existing device's sysfs queue limit. Change only the affected node/WWID
declarative rule to `8192`, wait for Omni sync, identify the block device by its
table WWID and verify its queue limit is `8192`. Only then
remove the rule. If an immediate runtime rollback is needed, set the matched
device's `/sys/block/<name>/queue/max_sectors_kb` to `8192` through the existing
CSI node pod and follow with the declarative change to prevent drift.
After the rule is removed, verify `8192` remains set and check again after a
device re-add before considering rollback complete.

Do not broaden these rules beyond the five listed LUN/node pairs without a
separate measured trial. The VMCluster remains in its temporary single-copy
maintenance routing while this is evaluated; restore its replication/routing
only after the volume is recovered and data gaps are reviewed.

## Prevention

Keep each rule restricted to its listed WWID and node; only vmstorage-1 has
the paired write-test evidence above. Recheck the queue limit after a TrueNAS
session reconnect, and remove the canary only after the underlying storage
issue is resolved and the 8192 KiB behavior has been re-evaluated.
