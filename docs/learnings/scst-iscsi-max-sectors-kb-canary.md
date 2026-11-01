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

The Omni Talos template adds a `UdevRulesConfig` rule for the exact test LUN
WWID `naa.6589cfc000000639f212aeb3d50f604d`, setting
`queue/max_sectors_kb=4096` on block disk add/change events. This rule is
scoped to that LUN on cp3; it does not cover other TrueNAS LUNs or the same
volume if it attaches to cp1/cp2.

Check the active value on cp3 through the existing privileged democratic-CSI
node pod, using its host `/sys` mount. Find the block name by WWID first; do not
assume it remains `/dev/sdh`:

```sh
for f in /sys/block/*/device/wwid; do
  if [ "$(cat "$f")" = naa.6589cfc000000639f212aeb3d50f604d ]; then
    name=${f#/sys/block/}
    name=${name%%/*}
    echo "$name: $(cat "/sys/block/$name/queue/max_sectors_kb") KiB"
  fi
done
```

Expect `4096`. Review the rule and Omni desired config before rollout. Talos
1.14.5 reloads changed udev rules and retriggers device discovery live, without
a node reboot; verify the sysfs value after reconciliation. See the [Talos
UdevRulesConfig reference](https://docs.siderolabs.com/talos/v1.14/reference/configuration/runtime/udevrulesconfig)
and [Talos udev controller](https://github.com/siderolabs/talos/blob/v1.14.5/internal/app/machined/pkg/controllers/files/udev.go).

## Rollback

Removing the rule alone does **not** restore the existing device's sysfs queue
limit. Change the declarative rule to `8192`, wait for Omni sync, identify the
block device by the WWID above and verify its queue limit is `8192`. Only then
remove the rule. If an immediate runtime rollback is needed, set the matched
device's `/sys/block/<name>/queue/max_sectors_kb` to `8192` through the existing
CSI node pod and follow with the declarative change to prevent drift.
After the rule is removed, verify `8192` remains set and check again after a
device re-add before considering rollback complete.

Do not broaden this canary to other LUNs or nodes without a separate measured
trial. The VMCluster remains in its temporary single-copy maintenance routing
while this is evaluated; restore its replication/routing only after the
volume is recovered and data gaps are reviewed.

## Prevention

Keep the rule restricted to the verified WWID and node; do not generalize from
this single trial. Recheck the queue limit after a TrueNAS session reconnect,
and remove the canary only after the underlying storage issue is resolved and
the 8192 KiB behavior has been re-evaluated.
