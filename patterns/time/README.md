# Time

## The problem

Certificates have a start and an end, revocation lists have a next-update time, tokens expire, backups are judged by
their age, and every log line carries a timestamp. All of it assumes the machines agree on the time. A machine whose
clock drifts refuses valid certificates, accepts expired ones, or writes log lines that no longer line up with the
others, and nothing says why.

Debian's default answers half of this. `systemd-timesyncd` asks one server, believes it, and keeps no record of
whether the answer was honest. This pattern makes every machine ask several servers, believe them only when they
agree, authenticate one of them, and report when it cannot.

## What runs here

**chrony on every machine,** declared by configuration management. Before this was written, ten machines here ran
timesyncd against one pool server each and three ran chrony from their images; nothing declared which, and nothing
watched the result. Now every server and development machine runs chrony against up to five sources:

- three servers authenticated with **NTS** (Network Time Security), from three operators (Cloudflare, Netnod and
  Germany's PTB): their answers are signed, so a forged one on the path cannot move the clock, and no one operator
  outvotes the others;
- Debian's pool, for two more answers.

None of them smears leap seconds. Google's servers do, spreading a leap second over a day; mixed with servers that
step, the two disagree by up to half a second around a leap. Use one kind or the other, never both.

**Agreement before action.** `minsources 2`: chrony moves the clock only when at least two sources are selectable,
that is, close enough to each other to be believed together, so a single bad source cannot steer it. With
`authselectmode` left at its default (`mix`), chrony prefers the authenticated sources and uses the others only
alongside them. `makestep 1 3`: a clock more than a second out is stepped, in the first three updates after chrony
starts only; after that it is slewed, so a service started later never sees time jump backwards (one started
earlier in the boot can).

**The chicken and the egg.** NTS starts with a TLS handshake, which checks a certificate, which needs the clock
roughly right. `nocerttimecheck 1` lets chrony skip the certificate's time check for its first handshake, while its
clock is not yet set. The cost: for that one handshake, an expired certificate would be accepted. Here one machine,
a small computer with no clock battery that lives behind a home router abroad, keeps systemd-timesyncd asking two
servers by address instead, so its clock does not depend on DNS or a tunnel at boot. It is declared, it is the
exception, and its offset is not judged by the rule below (only its sync flag is).

**The judges read chrony itself, and the kernel's flag.** The first version judged node_exporter's
`node_timex_offset_seconds`, the kernel's own offset. Under chrony that is always 0: chrony steers the clock without
the kernel's phase-locked loop, so the alert could never fire. A context-free review caught it; measured here, every
chrony machine read exactly 0. Debian's collectors package ships `chrony.py`, which prints chrony's tracking as
metrics, but no timer runs it; a one-minute timer here writes its output to node_exporter's textfile directory.
Three alert rules ([`time.yml`](time.yml)):

| Alert | Fires when |
|---|---|
| `ClockNotSynchronised` | the kernel's clock is marked unsynchronised (`STA_UNSYNC`), for 15 minutes |
| `ClockOffset` | chrony's own offset (`chrony_tracking_system_offset_seconds`) is more than 50 ms, ahead or behind, for 15 minutes |
| `ChronyFactsStale` | chrony's facts are more than 10 minutes old: chronyd is down or not answering. The kernel's flag can stay set for hours after chrony dies, so it cannot catch this |

A machine whose metrics stop arriving altogether is `InstanceDown`'s, not these.

50 ms is far tighter than certificates need (they tolerate minutes); it is where log lines from different machines
first stop lining up.

## The configuration, with example values

`/etc/chrony/chrony.conf`:

```
server time.cloudflare.com iburst nts
server nts.netnod.se iburst nts
server ptbtime1.ptb.de iburst nts
pool 2.debian.pool.ntp.org iburst maxsources 2
minsources 2
makestep 1 3
nocerttimecheck 1
ntsdumpdir /var/lib/chrony
driftfile /var/lib/chrony/chrony.drift
rtcsync
leapseclist /usr/share/zoneinfo/leap-seconds.list
logdir /var/log/chrony
```

`leapseclist`, not `leapsectz right/UTC`: Debian 13 does not install the `right/` zones without `tzdata-legacy`, and
a `leapsectz` pointing at a missing file does nothing. NTS needs TCP 4460 out (the key exchange) as well as UDP 123.

The facts timer, `/etc/systemd/system/chrony-facts.service` and `.timer` (`OnUnitActiveSec=1min`):

```
ExecStart=/bin/sh -c 'python3 -I /usr/share/prometheus-node-exporter-collectors/chrony.py > /var/lib/prometheus/node_exporter/.chrony.prom.tmp && mv /var/lib/prometheus/node_exporter/.chrony.prom.tmp /var/lib/prometheus/node_exporter/chrony.prom'
```

Installing chrony on Debian removes `systemd-timesyncd`; the two must not both run.

## The drill

[`drill-time.sh`](drill-time.sh) needs no credential.

**This machine (`machine`).** It asks chrony, read-only, how many sources it lists, how many are usable, which NTS
sources hold a key with cookies in hand, whether a source is selected, and how far off the clock is. Needs `chronyc`, and
root (or chrony's group), because chrony shows its NTS state only to them. Run without that, it exits 2 rather than
pass a check it could not see.

```
$ sudo ./drill-time.sh machine
ok    5 sources listed
ok    4 sources usable and agreeing
ok    authenticated (NTS) sources with cookies: time.cloudflare.com nts.netnod.se ptbtime1.ptb.de
ok    a source is selected
ok    offset -0.000793876s, within 50 ms
all checks passed
```

**The judges (`rules`).** promtool's unit tests ([`time.test.yml`](time.test.yml)) against the rules as published,
then against three copies with a guard removed: without the threshold, a clock 1 ms off is reported; without
`abs`, a clock running behind is never reported; without the age threshold, a chrony reporting every minute is called
stale. The tests must pass on the first and fail on all three. That second copy
failed to fail when the tests first held only a clock running ahead; a clock 200 ms behind was added.

```
$ ./drill-time.sh rules
ok    as-published: the tests pass, as they must
ok    no-threshold: the tests fail, as they must
ok    no-abs: the tests fail, as they must
ok    no-stale-age: the tests fail, as they must
all checks passed
```

## What is still open

- **The machines do not serve time to each other.** Each asks the internet. A site that loses its internet keeps
  time from its own drift until it returns. Making two machines per site serve the rest is not built.
- **The routers and appliances** keep their own clocks, and nothing here watches them.
- **The one machine on timesyncd** has no offset judged, only its sync flag.
