# A standby for the certificate authority

## The problem

When every server proves who it is with a short-lived certificate, the certificate authority (CA) is the one machine
everything else depends on. Here certificates live 24 hours and renew at two thirds of that, so a dead CA stops
nothing at once — and then, about eight hours later, identities start to expire, and within a day most services
refuse each other.

A backup of the CA's private key is not enough. The CA also holds a database: the ACME accounts every client
registered, and the record of what it issued. Rebuild a CA from its key alone and every ACME client has to register
again, by hand, on every machine. And the CA's own signing key usually exists in one place only: on the CA.

This pattern keeps a **cold standby**: a second machine in the other site holding a recent copy of the CA's whole
directory, the software installed and stopped, and **without the password** that unlocks the signing key. One
command turns it into the CA.

## What runs here

The CA is [step-ca](https://smallstep.com/docs/step-ca/). Its state is one directory, `/etc/step-ca`: `ca.json`, the
certificates, the signing keys **encrypted** with a key password, its templates, and a
[badger](https://github.com/dgraph-io/badger) database (the type is whatever `ca.json`'s `db.type` says; the script
reads it and checks only a badger directory). Two files in that directory hold passwords in clear (`password.txt`,
`provisioner-password.txt`), written there from the password manager by configuration management. **The root key is
never in this directory**: it lives in the password manager and is written back only to mint an intermediate. The
script refuses to send a directory holding `secrets/root_ca_key`, and the receiver refuses a copy carrying one.

Before this pattern the directory existed on the CA's machine and nowhere else.

### Setting up the two machines

Both machines get the same configuration-management role for the package, with one difference:

| | The CA | The standby |
|---|---|---|
| package | `step-cli` and `step-ca` from Smallstep's apt repository | the same |
| account | system user `step`, no shell, home `/etc/step-ca` | the same |
| directory | `/etc/step-ca`, owner `step`, mode 0700 | the same, filled only by the copy |
| unit | [`step-ca.service`](step-ca.service), enabled and running | the same file, **disabled and stopped** |
| `step ca init` | once, ever (it mints a root) | **never** |
| password files | written from the password manager | **deleted** if found |
| group | the CA group | the standby group |

The unit reads `--password-file /etc/step-ca/password.txt`. On the standby that file is not there, so neither a reboot
nor a stray `systemctl start` can make it a second CA.

### The copy

[`ca-standby.sh copy --from <CA> --to <standby>`](ca-standby.sh):

- **Sender**, under a lock: step-ca is **frozen** (`systemctl kill --signal=STOP`) only while its database is copied,
  then thawed (`--signal=CONT`). The copy runs under a 60-second timeout; a trap thaws the CA on exit, hangup,
  interrupt or termination; and a detached watchdog sends CONT seventy seconds later even if the sender is killed
  outright. No child that can outlive the sender inherits its lock. A frozen process writes nothing, so the copy is what the disk would hold if the machine crashed at
  that instant, which a database built to survive crashes opens. (Copying a live database without the freeze can
  capture one file before a write and another after it.) Requests wait while it is frozen; they are not refused. How
  long the freeze lasts was **not measured** on the real CA: it is the time to copy the database directory, and the
  script prints it. The copy is staged under `/var/tmp`, not `/tmp`, which is often a memory filesystem.
- The rest of the directory goes without the two password files and without a root key, followed by a **trailer**: a
  stamp and the sha256 of every file. The stamp is the time of the **data**: now, on a CA; on a standby relaying
  its copy, the time of that copy, so old data cannot pass for new.
- **Receiver**, under a lock: refused while it **could be a CA** — its step-ca running, its unit enabled (a restart or
  the next boot would start it), or a password file present. Refused when the copy is **older** than what it holds:
  its own copy's stamp, its database, or the time it was fenced if it was a CA (the fence records that). This stops
  a wrong-way copy, such as a reverse switch after a failed one; `--force` overrides it when that is really meant.
  Then the stream is unpacked into a staging directory and checked against the trailer: a cut stream, an altered
  file, a file the trailer does not list, a password file, a root key, or no `ca.json` is refused there.
- Only when **both ends** returned success is the staged copy installed. The previous copy is kept as
  `/etc/step-ca.prev`, and neither holds a password file afterwards.

### The check

`ca-standby.sh check --from <CA> --to <standby>` proves the copy is usable, not just present:

- every file except the database is equal on both machines (sha256);
- the copy is no older than a limit (26 hours by default), its stamp is not from the future (a wrong clock), and its
  database holds data files;
- the standby holds no password file and its step-ca is stopped and disabled. Each of these is read as an explicit answer, so an ssh
  failure fails the check instead of passing it;
- the database **opens**. The check runs `step ca init` in a scratch directory on the standby, with throwaway keys and
  a throwaway password, points that throwaway CA at a scratch copy of the database, starts it on loopback and asks
  `/health`. The real keys are never used.

Run the copy and then the check every night.

### The switch

`ca-standby.sh switch --from <old CA> --to <standby>`:

0. **Both password items** are read and must be non-empty (their bytes counted, never printed) before anything is
   touched.
1. **Fence** the old CA: stop and disable step-ca, delete its password files, record when it was fenced, and re-read
   that it is stopped, disabled, without a password and that its port (the address `ca.json` gives) refuses. If it does
   not answer, the switch refuses, because it may still be signing, unless `--from-down` says it is known to be down.
2. **A last copy** from the fenced CA, which is now quiet, so nothing is lost. With `--from-down` the standby's last
   copy stands.
3. Under **one lock** on the standby: **compare** the intermediate certificate that `ca.json` names, on disk, with the one
   you declared; only if it matches, **unlock** (each password from its own item, over stdin) and **start** step-ca. A
   stale or foreign copy is refused with nothing written.
4. **Probe**: `https://<CA name>/health` at the address `ca.json` gives (or the standby's address when that is every
   address or loopback), and the intermediate it serves is the declared one.

From step 3 on, any failure **rolls back**: step-ca is stopped and disabled on the standby and its password files are
deleted. The rollback then re-reads the standby and prints what it is; if it is not stopped, disabled and without a
password, it says **ROLLBACK FAILED** and what to run by hand.

Two things are never done by the script, and are part of the switch all the same:

- **The name.** Point the name clients dial at the standby.
- **The groups.** Exchange the two machines between the CA and standby groups in configuration management, in the same
  change. Otherwise the next run of configuration management writes the password back onto the old CA and starts it.

### When the old CA comes back

After a `--from-down` switch, nothing has fenced the old CA. If it returns and its unit starts, there are two CAs.
Before anything else touches it, run `ca-standby.sh fence --host <old CA>`. That makes it a standby: stopped, disabled,
no password, port refusing. Then copy onto it from the new CA as usual.

### Going back, and recovering from a failed switch

Going back is the same `switch` with the two machines exchanged, once the switch that brought you here **succeeded**:
its last line is `PASS switch`.

If a switch fails, it does not leave a half-started standby (the rollback above), but by then it may have fenced the
old CA. Do not run the reverse switch. If you do by mistake, its copy is refused when it carries older data than the
old CA held when it was fenced (the copy's stamp against the fence's), but recovering in place is the way:

- if the old CA's directory is intact, which it is because a fence deletes only the two password files, bring it back
  in place: write its two passwords, enable and start the unit, and check `/health`. That is what configuration
  management does when the machine is back in the CA group;
- if a failed copy left the standby with a bad directory, its previous copy is `/etc/step-ca.prev`.

### What it costs

The minutes the switch takes. If the old CA was down, ACME accounts registered after the last copy must register
again. Certificates issued after it are missing from the database; that matters only for revoking one of them by serial
before it expires within a day.

## The drill

[`drill-ca-standby.sh`](drill-ca-standby.sh) needs Docker and builds its image once ([`Dockerfile`](Dockerfile)):
Debian with step-ca from Smallstep's repository and sshd. The ssh user's login shell is dash and it has passwordless
sudo. Two stand-ins replace system tools: [`systemctl.sh`](systemctl.sh), for the one unit (its `stop` sends the kill
signal, then CONT, then SIGKILL after a grace, as systemd does), and [`cp.sh`](cp.sh), which fails a database copy on
demand, or hangs it so the sender can be killed mid-freeze. Container P runs a throwaway CA with two different
passwords, each chosen by its item name. Container S is an
empty standby. `ca-standby.sh` runs against them unchanged, through `docker exec`, and once through sshd.

The cases:

- P issues certificates, so the database has rows.
- The copy: P still answers afterwards and is not left stopped.
- The check passes, and refuses a stamp from the future.
- S cannot start by itself.
- A copy is refused while S's step-ca runs, while S holds a password file, and while S's unit is enabled.
- A failed database copy leaves P thawed and S's previous copy in place.
- A sender terminated mid-freeze thaws P at once; a sender killed outright is thawed by the watchdog.
- The check fails on a database that does not open, and a fresh copy replaces it.
- A wrong-way copy onto a newer, fenced CA is refused.
- The receiver refuses a cut stream, an altered file, a file the trailer does not list, a password file, a stream
  with no `ca.json` and a root key, and accepts a whole stream.
- Copy and check through sshd, where the login shell is dash.
- An empty password item stops the switch before the fence.
- The switch: P is fenced (stopped, disabled, no password, port closed), S holds each password from its own item, and
  S issues from the same provisioner.
- The switch back.
- A switch is refused when the old CA does not answer.
- Step 3 is refused while another run holds the standby's lock; then `--from-down` succeeds.
- A returning old CA that started itself is fenced.
- A failed start (a wrong key password) rolls back.
- A failed probe after a successful start (the CA listening where no client reaches it) rolls back to stopped and
  disabled.
- A foreign intermediate is refused before any password is written.

Then copies of the script, each with one guard removed, must each turn **their own named case** red:

| Arm | Guard removed | Its case |
|---|---|---|
| `no-exclude` | the sender leaves out the password files | the copy (the receiver refuses it) |
| `no-thaw` | the CA is thawed after the copy | P not left stopped |
| `no-error-thaw` | the trap thaws on an error | a failed database copy leaves P thawed |
| `no-signal-trap` | the traps thaw on a signal | a sender terminated mid-freeze thaws P at once |
| `no-watchdog` | the detached watchdog | a sender killed mid-freeze is thawed |
| `no-future-refusal` | the check refuses a stamp from the future | the stamp from the future |
| `no-run-refusal` | the receiver refuses while its CA runs | copy refused while S runs |
| `no-password-refusal` | the receiver refuses while it holds a password | copy refused while S holds a password file |
| `no-enabled-refusal` | the receiver refuses while its unit is enabled | copy refused while S's unit is enabled |
| `no-stale-refusal` | the receiver refuses older data | a wrong-way copy onto a newer CA |
| `no-trailer` | the receiver checks every file's sha256 | refuses an altered file |
| `no-unlisted` | the receiver refuses a file the trailer does not list | refuses an unlisted file |
| `no-recv-password` | the receiver refuses a password file in the copy | refuses a password file |
| `no-recv-cajson` | the receiver refuses a copy without `ca.json` | refuses a stream with no `ca.json` |
| `no-recv-rootkey` | the receiver refuses a root key | refuses the root key |
| `no-open-check` | the check opens the database | a database that does not open |
| `no-b64` | the remote program travels base64 to bash | copy through sshd, a dash login shell |
| `no-pw-precheck` | both password items are checked first | an empty item stops the switch before the fence |
| `no-fence-disable` | the fence disables the unit and checks it | P fenced: stopped, disabled, no password, port closed |
| `no-fence-refusal` | an unanswering old CA stops the switch | switch refused when the old CA does not answer |
| `no-step3-lock` | step 3 holds the standby's lock | step 3 refused while another run holds the lock |
| `no-fence-delete` | the fence deletes the password files | a returning host is fenced |
| `no-rollback` | a failure after unlocking rolls back | a failed start rolls back |
| `no-rollback-stop` | the rollback stops and disables | a failed probe after a start rolls back |
| `no-disk-compare` | the intermediate is compared before unlocking | a foreign intermediate is refused before unlock |

Three guards have no arm:

- **The probe's comparison of the intermediate served over TLS.** With the comparison on disk in place, no case can
  make the served intermediate differ from the one on disk.
- **Installing only after both ends succeed.** The trailer already refuses every cut stream the drill can make (a cut
  stream is caught by both the sums and the file count, so it has a case but no arm of its own).
- **Deleting password files from `.prev`.** The receiver refuses any host holding a password before it stages, so the
  drill cannot put one there.

They stay in the script as a second line.

```
$ ./drill-ca-standby.sh
== as published
  ok   P issues
  ...
ok    as-published: every case as expected
== arm no-exclude
ok    no-exclude: red on 'copy P -> S'
...
all checks passed
```

| Exit | Meaning |
|---|---|
| 0 | every case came out as expected and every arm was red on its own case |
| 1 | a case or an arm came out wrong; each BAD case prints the script's output |
| 2 | it could not run: no Docker, or the image did not build |

What the drill cannot show:

- the freeze's length and the switch's minutes on real machines;
- the name and the groups moving;
- systemd itself. In the containers the stand-in signals step-ca's own process. On a server, `systemctl kill` signals
  every process in the unit.

## What is still open

- **The nightly copy runs by hand** until a scheduled job runs the copy and then the check.
- **The person CAs**, which issue device and person certificates, keep their database in MariaDB. Their keys are in
  the password manager and their database is in the nightly backups, so they can be rebuilt. A standby for them is a
  standby for that database server.
