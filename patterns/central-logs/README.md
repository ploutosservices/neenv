# Central logs

## The problem

Every machine keeps its own journal, and keeps it only until it reaches its size limit, often a few days. Three
questions then have no answer. When did this service start failing, if that was last week? What happened on a
machine that is gone? What did someone with root on a machine do, if they tidied up after themselves?

The answer is a copy, made as each line is written, kept on another machine that the sender can add to and never
change. A carbon copy kept in a different building.

## What runs here

**The journal's own tools, nothing beside them.** Every server runs `systemd-journal-upload`, which reads its local
journal and sends each new entry, seconds after it is written, to one receiver. The receiver runs `systemd-journal-remote`, which
writes what arrives into ordinary journal files. Both come in one Debian package, `systemd-journal-remote`. A person
reads the store with the `journalctl` they already know:

```
journalctl -D /var/log/journal/remote _HOSTNAME=web1 --since yesterday -u nginx
```

There is no database, no new agent with its own configuration language, and no new query language. A searchable
store (Loki with an agent on every machine, read through Grafana) is the next step if `journalctl` over files stops
being enough. For a fleet of about a dozen servers it has not.

**One store.** Every sender's entries go into one set of journal files (`SplitMode=none`). Each entry keeps the
fields the sender's journal gave it, `_HOSTNAME` among them, so one machine's lines are a filter away. `_HOSTNAME` is
the sender's own claim, stored as sent: it says which machine a line is about, not which certificate sent it. A
holder of any sender's certificate could write lines under another machine's name. Which certificate sent each
batch is in the door's access log (below), and that is the record to trust when the two disagree.

**The door is the web server, not journal-remote.** journal-remote can terminate TLS itself, and it then accepts any
client certificate its trusted CA signed. If that CA also signs every service's certificate, as an estate CA does,
then every service could write into the log store. So journal-remote listens in plain HTTP on loopback, and nginx in
front of it:

- holds TLS for the store's name (`logs.home.arpa` in the examples), with a certificate from the private CA;
- asks for a client certificate and answers 403 to a caller without a valid one from that CA. A certificate from a
  foreign CA fails TLS verification and gets nginx's 400 instead;
- admits only certificates whose subject is a log sender's: `CN=journal-<host>@home.arpa`. Any other service's
  certificate is 403 too;
- logs, for every request, the verify result and the subject of the certificate that sent it;
- passes each upload straight through. journal-upload sends a POST every few seconds while entries arrive, with a
  chunked body of unknown length: `proxy_request_buffering off` hands it on as it comes, and `client_max_body_size 0`
  lifts nginx's 1 MB limit, which a sender catching up on old entries exceeds. (Measured here: one sender, 92 POSTs in
  15 minutes, each answered 202.)

**Each sender has its own certificate,** `journal-<host>@home.arpa`, from the private CA (step-ca here, the CA of
[The root of trust](../root-of-trust/README.md)). The configuration run makes it: on the CA's machine it asks for a
one-time token for exactly that name (`step ca token journal-web1@home.arpa`), and on the sender `step ca
certificate` makes the key and exchanges the token for a certificate. The key never leaves the sender. Only the
configuration run can mint a token, because only the CA's machine holds the provisioner's password, so nobody else
can obtain a `journal-*` name. The certificate file holds the leaf and the intermediate, which is what nginx needs to
verify it against the root (`ssl_verify_depth 2`). The sender renews it with its own timer (`step ca renew`, over
TLS with the certificate it holds), and the renewal restarts the uploader. The key is readable by root and one group,
`journal-upload`; journal-upload runs as a dynamic user and is given that group.

**What "cannot change" means here.** A sender can only append: nothing in the upload protocol edits or deletes an
entry. Two limits on that. Root on the receiver can do anything; the receiver is one more machine to protect, not a
write-once medium. And retention is by size for the whole store, so a sender that floods it pushes the oldest
history of every machine out early. Per-sender stores with per-sender limits would close that; they are not built.

**Which machines send.** Every production and staging server, and the receiver itself, through its own door.
Development machines do not: development and production do not share stores.

**Retention is by size.** `MaxUse=` on the receiver. Here the fleet writes about 1.1 GB a day in journal export
form, and journal files are compressed. 200 GB is about three months. At the limit the oldest file goes.
`KeepFree=` keeps the disk itself from filling. Both keys are read by the systemd 257 that runs here; check your
version's `journal-remote.conf` manual page, because a systemd that does not know them ignores them and the store
grows until the disk is full. A new sender's first run also sends its whole local journal, so the store jumps when a
machine joins (here 2.4 GB in the first minutes, for eleven machines).

**Watching it.** A timer on the receiver lists, every 5 minutes, which hosts the store heard from in the last 15
minutes, and its size ([`central-logs-facts`](central-logs-facts)). Two alert rules judge it
([`central-logs.yml`](central-logs.yml)):

| Alert | Fires when | Why |
|---|---|---|
| `CentralLogsSenderQuiet` | a server answers its scrape, but the store has not heard it for 30 minutes | every server writes to its journal at least every 15 minutes (a timer's run is enough), so silence means the upload stopped |
| `CentralLogsUnread` | the store could not be read, the facts were never written, or the facts file is more than 15 minutes old | node_exporter keeps serving the last file when the timer stops, and every number in it then looks current; only the file's age shows it |

The first rule joins on the `instance` label, compared with the sender's short host name. Here every node exporter's
target is labelled with the machine's short name (`instance="web1"`). Where `instance` carries a port or a domain
(`web1.home.arpa:9100`), strip it with `label_replace` in the rule, or relabel the targets.

**Four traps met building it.** journal-upload, journal-remote and the configuration tool each have one:

- journal-upload, given a URL with no port, dials 19532, its own default, not 443. Write the port.
- With one store, `--output` must name a file (`.../remote.journal`). A directory is refused: "output must be a file".
- The packaged receiver unit has `LogsDirectory=journal/remote`. systemd creates that directory and owns it to the
  service user at every start, so do not manage it yourself.
- Ansible's `apt_repository` module, used to add the CA tool's repository on each sender, refuses to run without
  `gpg`, even for a repository signed by a key file. A minimal server may not have it.

## The configuration, with example values

On each sender, `/etc/systemd/journal-upload.conf`:

```
[Upload]
URL=https://logs.home.arpa:443
ServerKeyFile=/etc/identity/journal-web1/key.pem       # 0640 root:journal-upload
ServerCertificateFile=/etc/identity/journal-web1/cert.pem # the leaf, then the intermediate
TrustedCertificateFile=/etc/ssl/certs/ca-certificates.crt
```

and a drop-in, `/etc/systemd/system/systemd-journal-upload.service.d/local.conf`. journal-upload exits when the
receiver does not answer, so it is restarted for ever, never given up on:

```
[Unit]
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
SupplementaryGroups=journal-upload
Restart=always
RestartSec=30
```

On the receiver, `/etc/systemd/journal-remote.conf`:

```
[Remote]
Seal=false
SplitMode=none
MaxUse=200G
KeepFree=50G
```

`/etc/systemd/system/systemd-journal-remote.socket.d/local.conf`, loopback only:

```
[Socket]
ListenStream=
ListenStream=127.0.0.1:8361
```

`/etc/systemd/system/systemd-journal-remote.service.d/local.conf`, plain HTTP from the socket into one file:

```
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-journal-remote --listen-http=-3 --output=/var/log/journal/remote/remote.journal
```

The door, an nginx server block:

```nginx
server {
    listen 443 ssl;
    server_name logs.home.arpa;
    ssl_certificate     /etc/ssl/logs.home.arpa/fullchain.pem;
    ssl_certificate_key /etc/ssl/logs.home.arpa/privkey.pem;

    ssl_client_certificate /usr/local/share/ca-certificates/private-root.crt;
    ssl_verify_depth 2;                  # leaf, intermediate, root
    ssl_verify_client optional;          # so a refusal is a 403 the caller can read, not a TLS error
    if ($ssl_client_verify != SUCCESS) { return 403; }
    if ($ssl_client_s_dn !~ "^CN=journal-[a-z0-9-]+@home\\.arpa$") { return 403; }   # inside quotes nginx reads \\ as one backslash
    access_log /var/log/nginx/access.log identity;   # with $ssl_client_verify and $ssl_client_s_dn in the format

    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    location / {
        proxy_pass http://127.0.0.1:8361;
        proxy_http_version 1.1;
    }
}
```

The facts timer on the receiver runs `central-logs-facts /var/log/journal/remote
/var/lib/prometheus/node_exporter/central-logs.prom` every 5 minutes, as root (the store's files are readable by
its service user only), from a oneshot service and a timer with `OnUnitActiveSec=5min`. node_exporter on the receiver
reads that directory (`--collector.textfile.directory=/var/lib/prometheus/node_exporter`).

Putting it together, in order: the CA's root trusted on every machine; a DNS record for `logs.home.arpa` pointing at
the receiver, and port 443 reachable from every sender (here over the private network and the mesh); on the receiver
the package, the three files above, `systemctl enable --now systemd-journal-remote.socket`, the door, its
certificate and the facts timer; on each sender the package, the `journal-upload` group, the certificate, the two
files above and `systemctl enable --now systemd-journal-upload.service`.

## The drill

[`drill-central-logs.sh`](drill-central-logs.sh) needs no credential.

**The door and the store, on one machine (`local`, the default).** It makes a throwaway CA, a certificate for the
door, and two callers: a log sender (`journal-web1@home.arpa`) and another service (`other-app@home.arpa`). It starts
journal-remote on loopback and nginx in front of it, configured as above. It writes three journal entries into a
small journal file and uploads it with journal-upload, once as each caller (`--follow=no`: send, then exit), and
once with curl and no certificate. Then it asks the store what arrived. It runs as any user. Needs curl, openssl,
nginx and the `systemd-journal-remote` package. If the store or the door does not come up on its random port, it
says so and exits 2: a setup fault is never a FAIL.

```
$ ./drill-central-logs.sh
door on 127.0.0.1:33558, store on 127.0.0.1:29569, journal-* only
ok    a log sender's upload is accepted
ok    all 3 of its entries are in the store
ok    each entry keeps the host name it was sent with
ok    another service's certificate is refused (403)
ok    a caller with no certificate is refused (403)
ok    the refused callers added nothing to the store
all checks passed
```

A refusal counts only as nginx's 403, found in journal-upload's own words (`failed with code 403`). A TLS failure or
a dead store would also turn a caller away and prove nothing. Without the subject rule, exactly the other service's
refusal must fail; every certificate the CA signed would then be a log sender:

```
$ ARM=nosubject ./drill-central-logs.sh
...
FAIL  another service's certificate was not refused with 403:
...
ARM: exactly the 'other identity refused' check failed without the subject rule, as it must
```

On a machine that is itself a sender, journal-upload also reads its own URL from `/etc/systemd/journal-upload.conf`
(or a drop-in under `journal-upload.conf.d/`) and refuses a second one. The drill then runs it in a private mount
namespace (`unshare -rm`) with both hidden. That needs unprivileged user namespaces, which Debian allows; where they
are refused (Ubuntu's AppArmor setting can), the drill exits 2 and asks to be run on another machine.

The drill sends a finished file. It does not exercise a sender following a live journal for hours; the alert rules
are what watch that.

**The judges (`rules`).** promtool's unit tests ([`central-logs.test.yml`](central-logs.test.yml)) against the rules
as published, then against three copies with a guard removed: without the `unless`, every server is reported quiet;
without the `absent`, a receiver whose facts were never written is never noticed; without the file's age, a timer
that stopped while its last file is still served is never noticed. The tests must pass on the first and fail on all
three. Needs promtool.

```
$ ./drill-central-logs.sh rules
ok    as-published: the tests pass, as they must
ok    no-unless: the tests fail, as they must
ok    no-absent: the tests fail, as they must
ok    no-file-age: the tests fail, as they must
all checks passed
```

## What is still open

- **Reading by owner.** Only root and the journal group on the receiver read the store, so whoever runs the
  platform reads everything. Letting each application's owner read only its own services' lines would need a small
  service in front of the store that checks the caller and filters by unit. Here one such read exists for one
  journal on one machine (a scheduler's job results, served only to the two owners who need them), and it is the
  shape a general one would take.
- **Devices are not senders.** Cameras, switches and other appliances log to their vendor, or nowhere. A device
  bridge that runs scheduled jobs writes each job's start, result and exit code to its own journal, and that
  journal is shipped like any other. The devices themselves are not.
- **A copy of the store.** The store is backed up with the rest of its machine. A second receiver at another site,
  or a nightly copy off site, is not built.
- **What the logs hold.** Applications write what they write. Nothing here strips a tenant's data or a token from a
  log line before it is shipped. That is each application's discipline, and it is not checked.
- **Sealing.** journal files can be sealed (Forward Secure Sealing), so tampering by root on the receiver would show.
  It is off (`Seal=false`).
