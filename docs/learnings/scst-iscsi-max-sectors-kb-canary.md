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
setting `queue/max_sectors_kb=4096` on block disk add/change events for all
TrueNAS WWIDs matching `naa.6589cfc000000*` on cp1/cp2/cp3. The five original
exact rules remain after the prefix rule as fallbacks and canary history:

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
After PR #1432, all five exact matches were verified live at 4096 KiB, but
TrueNAS again logged thousands of `Allocation of sgv_pool_obj failed (size
8388608)` errors per minute. The scope therefore expands to all connected
TrueNAS LUNs; this remains mitigation, not a verified root-cause fix. The live
inventory found 36 connected TrueNAS LUNs across cp1/cp2/cp3 with this prefix;
QEMU OS disks had empty WWIDs. Recheck that inventory before rollout. The prefix
also covers future matching LUNs and volumes moving between these nodes.

[udev supports shell-glob matches](https://www.freedesktop.org/software/systemd/man/latest/udev.html).
The Talos controller linked below writes rule strings unchanged to udev.

Before and after reconciliation, inventory every disk through each existing
privileged democratic-CSI node pod's host `/sys` mount:

```sh
for disk in /sys/block/*; do
  wwid=$(cat "$disk/device/wwid" 2>/dev/null || true)
  printf '%s %s %s KiB\n' "${disk##*/}" "$wwid" "$(cat "$disk/queue/max_sectors_kb")"
done
```

Expect every connected TrueNAS-prefix LUN at `4096` on all three nodes;
compare counts with the current inventory (36 at investigation time). Verify
all other disks retain their recorded values. Resolve devices by WWID, never
assume stable sdX names. Recheck after reconnect/re-add and cold boot.
After reconciliation, monitor node
write timeouts/EIO, vmstorage fsync failures/restarts and the TrueNAS SCST
journal across representative workload. Quiet samples alone do not establish
durable recovery. Review the rule and Omni desired config before rollout. Talos
1.14.5 reloads changed udev rules and retriggers device discovery live, without
a node reboot; verify the sysfs value after reconciliation. See the [Talos
UdevRulesConfig reference](https://docs.siderolabs.com/talos/v1.14/reference/configuration/runtime/udevrulesconfig)
and [Talos udev controller](https://github.com/siderolabs/talos/blob/v1.14.5/internal/app/machined/pkg/controllers/files/udev.go).

## Rollback

Removing a rule alone does **not** restore the existing sysfs queue limit.
First change the generic prefix rule on all three nodes to `8192`, keeping it
before the five exact `4096` rules. Wait for Omni sync and verify all matching
LUNs except those five are at `8192`; those five must remain at `4096` because
the later exact assignments win. Only then remove the generic rules and check
that state again, including after device re-add. Roll back an exact canary
separately by changing its exact rule to `8192`, verifying, then removing it.

The VMCluster remains in temporary single-copy maintenance routing; restore
replication/routing only after volume recovery and data-gap review.

## Prevention

Keep the prefix restricted to inventoried TrueNAS LUNs and retain the exact
fallbacks until cluster-wide behavior is evaluated. Only vmstorage-1 has paired
write-test evidence. Recheck after reconnect and remove the mitigation only
after the underlying issue and 8192 KiB behavior have been re-evaluated.
