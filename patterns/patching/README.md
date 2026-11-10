# Patching

## The problem

A machine that faces the internet runs daemons with published vulnerabilities from the day the fix ships until
the day the fix is installed, and a fixed kernel or library protects nothing until the process using it restarts.
Two easy answers are both wrong. Patching by hand is forgotten. Patching everything automatically, reboots
included, takes services down at an hour nobody chose.

This pattern splits the work in two, the way Debian's own tools already do: **security fixes go in by themselves
every night, with no reboot**; **the full upgrade and the reboot happen once a month, one machine at a time, in a
slot chosen in advance**. Then it makes both halves *visible*, because the failure that matters is the one nobody
sees: the update that stopped going in, and the reboot that never happened.

## What runs here

**Nightly: security updates only.** Every Debian-family machine runs `unattended-upgrades` from apt's own timers
(`apt-daily.timer` refreshes the package lists, `apt-daily-upgrade.timer` installs). It takes packages from the
security pockets only (Debian's `-security` and Ubuntu's `-security`), never from the main archive, so a nightly
run changes as little as possible. It **never reboots by itself**. A kernel is not excluded: a security kernel is
installed and waits for the monthly reboot. Debian then writes `/var/run/reboot-required`, which says so.

The configuration is declared by configuration management, not inherited from the package. Two traps were met
writing it:

- `Origins-Pattern` takes `key=value` pairs only. The older `Allowed-Origins` form (`"Ubuntu:noble-security"`)
  in an `Origins-Pattern` block makes `unattended-upgrade` crash while parsing, and nothing reports it. The
  declaring step therefore runs `unattended-upgrade --dry-run --debug` after writing the file, so a syntax error
  fails the run instead of every night after it.
- A distribution upgrade changes the codename. The patterns use `${distro_codename}`, never a literal name.

**Monthly: the full upgrade and the reboot.** A scheduled job runs on the first Sunday of the month, one machine
per slot, half an hour apart. The slots are what keep it to one machine at a time: nothing makes a slot wait for
the machine before it to come back, so the gap must be longer than a reboot. It does five things, in order:

1. **Refuse an unwell machine.** If a service meant to stay up has already failed, the job stops before touching
   anything: a reboot would hide the failure and might make it worse. A failed oneshot started by a timer is not a
   stop; its next run decides.
2. **Drain the scheduler's workers on that machine,** so no job dies halfway through the reboot.
3. `apt-get full-upgrade`.
4. **Reboot, if anything asks for one:** `/var/run/reboot-required` exists or the newest installed kernel is not the
   running one. The reboot is scheduled five seconds out (`systemd-run --on-active=5 systemctl reboot`), so the
   job can report before the machine goes down.
5. Report the before and after kernel.

A service that binds a specific address must be told to wait for it. The first monthly reboots here left nginx
failed with `bind() ... Cannot assign requested address`: the address came from DHCP after the network was
declared online. Two fixes are used here. nginx's machines tell the kernel it may bind an address it does not hold
yet (`net.ipv4.ip_nonlocal_bind=1`), so the socket answers the moment the address arrives. The node exporter gets a
drop-in with `After=` and `Wants=` for what its addresses depend on (`After=` alone pulls nothing in), and
`RestartSec=5s`, because the packaged unit's 100 ms retries use up systemd's start limit within a second.

**Watching both halves.** Debian's `prometheus-node-exporter-collectors` package (installed with the exporter)
runs a timer that writes `apt.prom` every 15 minutes:

| Metric | What it says |
|---|---|
| `apt_upgrades_pending{origin}` | updates waiting, by the archive they come from |
| `apt_package_cache_timestamp_seconds` | when the package lists were last refreshed |
| `node_reboot_required` | 1 while `/var/run/reboot-required` exists |

It writes them to `/var/lib/prometheus/node-exporter/`, **with a hyphen**. That is also the Debian package's own
default for the exporter, so the facts are read until someone gives the exporter a directory of its own. An
exporter configured with its own textfile directory reads only that one. When this pattern was written, every machine here had `apt.prom` written
fresh, and not one of them served it: the exporter read `/var/lib/prometheus/node_exporter/`, with an
underscore. The facts existed, and nobody could see them. The fix is one flag: `--collector.textfile.directory`
is repeatable in node_exporter 1.9 (its `--help` says so), so the exporter reads both. An older exporter may refuse
the second flag and not start: check `--help` first, and if it is not repeatable, write your own files into the
collectors' directory instead.

Five alert rules judge the facts ([`patching.yml`](patching.yml)):

| Alert | Fires when | Why that line |
|---|---|---|
| `SecurityUpdatesUnapplied` | a security-origin update has been pending 3 days | the nightly run should have taken it; 3 days covers an update released after the night's run |
| `RebootPending` | a reboot is required **and** the machine has been up more than 37 days | first Sundays are 28 or 35 days apart, so a waiting reboot is normal for up to 35 days; 37 leaves a slot room to run late |
| `AptListsStale` | the package lists are more than 2 days old | the nightly run is installing from an old view |
| `PatchFactsStale` | `apt.prom` has not been written for 2 hours | the timer writes every 15 minutes; a stopped timer leaves the last file served, and every number in it looks current |
| `PatchFactsMissing` | a machine answers its scrape but serves no `apt_package_cache_timestamp_seconds` | the facts are not reaching the exporter (the defect above), so the others cannot fire |

`RebootPending` is judged from `node_boot_time_seconds`, not from a long `for:`. Prometheus keeps a pending
alert's clock across its own restarts, but a `for:` starts again if the series is missing for a single
evaluation (an exporter restart, one lost scrape), and over a month that will happen. `SecurityUpdatesUnapplied`
keeps a 3-day `for:` and accepts that weakness: a missed scrape can push it later, never earlier. The first version
of `RebootPending` fired after 7 days and was wrong: it would have fired every month between slots.

On its first run here the rules found two machines a person had to look at. Both were development machines,
which have no monthly slot, up 51 and 69 days with a reboot waiting.

## The configuration, with example values

`/etc/apt/apt.conf.d/20auto-upgrades`:

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
```

`/etc/apt/apt.conf.d/50unattended-upgrades`:

```
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=Ubuntu,archive=${distro_codename}-security,label=Ubuntu";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::SyslogEnable "true";
```

`/etc/default/prometheus-node-exporter`, both textfile directories:

```
ARGS="--collector.textfile.directory=/var/lib/prometheus/node_exporter --collector.textfile.directory=/var/lib/prometheus/node-exporter --web.listen-address=10.0.0.21:9100"
```

The monthly job, as a sketch of its shape. The scheduler runs it every Sunday, one machine per slot; the
schedules have six fields, seconds first (`0 0 5 * * 7` for the first machine, `0 30 5 * * 7` for the second, and so
on). It returns at once on any Sunday but the first:

```bash
[ "$(date +%d)" -le 7 ] || exit 0
failed=$(systemctl --failed --no-legend --plain | awk '{print $1}')
[ -z "$failed" ] || { echo "refused: failed before patching: $failed"; exit 1; }
before=$(uname -r)
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y \
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade || exit 1
newest=$(ls -1 /boot/vmlinuz-* | sort -V | tail -1 | sed 's#.*/vmlinuz-##')
if [ -f /var/run/reboot-required ] || [ "$newest" != "$before" ]; then
  echo "rebooting: kernel $before -> $newest"
  systemd-run --on-active=5 --unit=patch-reboot systemctl reboot
fi
```

`--force-confold` keeps a configuration file you changed when a package ships a new one; without it the upgrade
stops at a question nobody is there to answer. The real job also drains the scheduler's workers on the machine first
and lets a failed timer-driven oneshot through; both depend on what the machine runs.

## The drill

[`drill-patching.sh`](drill-patching.sh) needs no credential. It has three parts.

**The facts reach the exporter (`local`, the default).** It starts a throwaway node_exporter on loopback with only
the textfile collector, and two directories: its own, holding one ordinary fact, and the collectors' one, holding an
`apt.prom` with a pending security update, a list age and a waiting reboot. Needs bash, curl and node_exporter
(`NODE_EXPORTER_BIN=/path` picks one).

```
$ ./drill-patching.sh
node_exporter on 127.0.0.1:30122, both directories
ok    the machine's own fact is served
ok    pending security updates are served
ok    the package lists' age is served
ok    a waiting reboot is served
all checks passed
```

With the collectors' directory left out, which is the defect this pattern found, exactly the three patch facts must
fail. The machine's own fact must still pass:

```
$ ARM=onedir ./drill-patching.sh
node_exporter on 127.0.0.1:28433, its own directory only
ok    the machine's own fact is served
FAIL  pending security updates are not served
FAIL  the package lists' age is not served
FAIL  a waiting reboot is not served
ARM: exactly the 3 patch-fact checks failed with one directory, as they must
```

**The judges (`rules`).** It runs promtool's unit tests ([`patching.test.yml`](patching.test.yml)) against the
rules as published, then against five copies with one guard removed each. The tests must pass on the first and fail
on every copy, or the tests could not tell a guard from its absence. Needs promtool.

```
$ ./drill-patching.sh rules
ok    as-published: the tests pass, as they must
ok    no-wait: the tests fail, as they must
ok    no-uptime-guard: the tests fail, as they must
ok    no-list-age: the tests fail, as they must
ok    no-write-age: the tests fail, as they must
ok    no-unless: the tests fail, as they must
all checks passed
```

**This machine (`machine`).** On a real Debian-family machine it reads `apt-config dump` and checks the nightly
run is on, the lists refresh, nothing reboots by itself, and every allowed origin is a security one (label
`Debian-Security`, or an archive or codename ending in `-security`). It also checks that `apt.prom` was written in the
last hour, and that the exporter, at the address its own configuration names (`EXPORTER=host:port` overrides),
serves the patch facts. An exporter that does not answer is reported as skipped, never as passed.

```
$ ./drill-patching.sh machine
ok    unattended-upgrades is installed
ok    it runs nightly
ok    the lists refresh nightly
ok    it never reboots by itself
ok    every origin it takes is a security origin
ok    /var/lib/prometheus/node-exporter/apt.prom was written in the last hour
ok    the exporter at 10.0.0.21:9100 serves the patch facts
all checks passed
```

## What is still open

- **Application dependencies are not covered.** Language packages (npm, pip, composer) and container images are
  pinned in each application's repository, and nothing here reports a known vulnerability in one. That is a
  dependency bot (Renovate) or a scanner (osv-scanner) per repository, run by each repository's own checks. It is
  not built.
- **A library update does not reach a running daemon.** `/var/run/reboot-required` is written for a new kernel,
  not for a library. A daemon keeps the old library mapped until it restarts. `needrestart` would list them, or
  restart them; it is not used here, and the monthly reboot is what clears them.
- **Development machines have no monthly slot.** A reboot there ends every session running on it, so it is a
  person's decision, and `RebootPending` is what reminds them.
- **No live kernel patching.** A kernel fix waits up to a month for its slot. Live patching would close that gap.
  It is not used.
- **Devices.** Cameras, switches, thermostats and the like run their vendor's firmware. The vendor patches it, not
  us. A device register can record the firmware version it reads from each device. Here that field is filled on
  about a quarter of the devices, because many vendors' interfaces do not report it. An update stays the vendor's.
- **Containers** pulled by tag get their base image's fixes only when they are pulled again. Pulling on the monthly
  slot is not built.
