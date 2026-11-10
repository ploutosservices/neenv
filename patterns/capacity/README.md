# Capacity: full disks and failing drives, a week early

## The problem

The usual disk alert fires at a level: 80% used. It says nothing about a disk at 60% that is filling at 5% a day,
and when it does fire, the time left may be an hour or a month. A drive's own health is another blind spot: drives
report their failure through SMART and NVMe health logs long before they stop, and nobody reads them.

## What runs here

**A trend, beside the level.** The usual level rule (80% used) is kept, separately; it is not in this file. Beside it,
`DiskWillFillIn7Days` projects the last three days of free space a week ahead with `predict_linear`, and pages when
that reaches zero. It does so only on a filesystem already past 70% used, so a log burst on an empty disk does not
page. The cost of that guard: a disk at 50% that will fill in three days is not reported by this rule until it passes
70%.

**The drives' own verdicts.** Debian's `prometheus-node-exporter-collectors` package runs `smartmon` and `nvme`
collectors every 15 minutes (`apt install prometheus-node-exporter-collectors smartmontools nvme-cli`: the two tools
are only recommended by the package), writing each drive's SMART health, NVMe critical-warning bits, wear (percentage of rated
endurance used) and spare capacity as metrics. Two traps sit in front of them:

- **The facts were not read.** The collectors write to `/var/lib/prometheus/node-exporter/`, and an exporter with its
  own textfile directory does not read that one ([Patching](../patching/README.md) has the fix: a second
  `--collector.textfile.directory`).
- **The smartmon timer did not run on NVMe-only machines.** The packaged timer carries
  `ConditionPathExistsGlob=|/dev/sd*` and `|/dev/hd*`, evaluated once at boot. A machine whose only drive is NVMe
  never started it. Measured on one machine here: its smartmon file was 160 days old, its timer enabled and
  inactive, and every number in it looked current. A drop-in clears the condition. An empty `Condition…=` resets
  *every* condition of the unit, so the drop-in puts back the one worth keeping, that `smartctl` exists.
- **NVMe is the nvme collector's.** smartmon reports an NVMe drive as SMART *not available* (its output lacks the line
  smartmon looks for), so the SMART rule never fires for one; the NVMe rules cover it.

**Virtual disks report no SMART.** A cloud machine's disks answer `smart_available 0` and `smart_healthy 0`. A rule
on `healthy` alone pages on them for ever. The rule here requires `available` too, matched on the drive's `type` as
well as its device, because behind a RAID controller one `/dev/sdX` is several drives.

**A file that never existed cannot go stale.** On a fresh machine whose timer never ran there is no `smartmon.prom`,
so no age to judge; a sixth rule reports a machine that answers its scrape and serves no drive facts at all.

node_exporter 1.9 here: it accepts the textfile flag more than once and labels each file with its full path, which
the age rules match on. Check both with `--help` and `/metrics` on an older exporter.

Six rules ([`capacity.yml`](capacity.yml)):

| Alert | Fires when |
|---|---|
| `DiskWillFillIn7Days` | a filesystem past 70% used reaches zero free space within seven days at the last three days' rate, for 6 hours |
| `DriveSmartUnhealthy` (critical) | a drive that offers SMART fails its own health check |
| `NvmeCriticalWarning` (critical) | an NVMe drive raises any critical-warning bit: spare low, temperature, reliability, read-only, backup power |
| `NvmeWearHigh` | an NVMe drive has used 80% of its rated endurance: time to buy its replacement |
| `DriveFactsStale` | a drive facts file is more than 3 hours old: its timer stopped, and old numbers are being served |
| `DriveFactsMissing` | a machine answers its scrape and serves no `smartmon.prom` at all, for 2 hours |

## The configuration, with example values

The smartmon timer drop-in, `/etc/systemd/system/prometheus-node-exporter-smartmon.timer.d/local.conf`:

```
[Unit]
ConditionPathExistsGlob=
ConditionFileIsExecutable=/usr/sbin/smartctl
```

then `systemctl daemon-reload && systemctl enable --now prometheus-node-exporter-smartmon.timer
prometheus-node-exporter-nvme.timer`. The exporter reads the collectors' directory:

```
ARGS="--collector.textfile.directory=/var/lib/prometheus/node_exporter --collector.textfile.directory=/var/lib/prometheus/node-exporter"
```

The rules themselves are [`capacity.yml`](capacity.yml), not repeated here.

## The drill

[`drill-capacity.sh`](drill-capacity.sh) runs promtool's unit tests ([`capacity.test.yml`](capacity.test.yml)) against
the rules as published, then against five copies with one guard changed each. The tests drive each rule red (disks
losing 1 GB and 0.2 GB an hour from 25 GB free, a drive failing SMART, an NVMe warning, 85% wear, a facts file whose
timer stopped, a machine with no facts file) and keep a quiet case beside each (a steady disk, a filling disk that is
mostly empty, a virtual disk with no SMART, files written every five minutes). Each copy must still parse, and its
tests must fail on the alert it broke; a copy that breaks something else, or no longer parses, does not count. Needs
promtool.

```
$ ./drill-capacity.sh
ok    as-published: the tests pass, as they must
ok    no-level-guard: the tests fail, as they must (on DiskWillFillIn7Days)
ok    one-day-horizon: the tests fail, as they must (on DiskWillFillIn7Days)
ok    no-available-guard: the tests fail, as they must (on DriveSmartUnhealthy)
ok    no-facts-age: the tests fail, as they must (on DriveFactsStale)
ok    no-missing-guard: the tests fail, as they must (on DriveFactsMissing)
all checks passed
```

On a real machine, the check is the facts themselves: `curl -s localhost:9100/metrics | grep -E
'^(smartmon_device_smart_healthy|nvme_critical_warning|nvme_percentage_used_ratio)'` must print a line per drive, and
`node_textfile_mtime_seconds` for `smartmon.prom` and `nvme.prom` must be minutes old, not days.

## What is still open

- **Growth beyond a week** (a forecast for buying disks, months ahead) is not built. The three-day trend is for
  operations, not purchasing.
- **Drives behind a USB bridge or a RAID controller** may not pass SMART through; `smart_available 0` then hides them
  exactly as it hides a virtual disk.
- **The NAS units' own drives** report through their own systems, not these collectors.
