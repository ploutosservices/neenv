# Disaster recovery, with succession

## The problem

Backups that run every night answer one question: is there a copy? A disaster asks three others. Can the copy be
read without the machine that made it? In what order does an estate come back when nothing is running? And who does
it, if the one person who decides everything cannot? An estate with one decider has one more single point than its
servers: that person.

## What runs here

**Every store is backed up each night and the backup copied abroad.** Each database, file tree and configuration
export goes, as a restic snapshot, to a REST server at home, and is then copied to a twin in another country. The
twin is **append-only**: it accepts new snapshots and refuses to delete or overwrite one, so a machine at home that
is compromised, or a mistake, cannot reach back and erase the copy abroad. Pruning the twin is a separate, scheduled
job, not something a backing-up machine can do. Each login reaches only its own repository (`--private-repos`).
Append-only is narrower than it sounds: a holder of the append login can still write a newer snapshot, an empty or a
false one, and `restore latest` would then return it; it can fill the disk; and a prune that keeps by count (the last
seven daily snapshots) can be made to drop real ones by writing many. So a restore names a snapshot that was checked,
not `latest`, and the twin's prune is the next thing to move to keeping by time (`--keep-within`).

**A restore is proved every day, not assumed.** A morning job restores the newest artefact of each dataset into an
empty scratch database and counts real rows. On the day this was written, sixteen of twenty-two artefacts were
proven that way: fifteen databases loaded with their tables and rows counted, and the sign-in door's database
restored onto a scratch server and signed in through. The other six were named for what they are (a file tree
present, an archive that opens, a router export present, a mirror matching its manifest) rather than counted as
restores.

**Recovery point, measured.** The newest good copy of every store was under 26 hours old, with one exception that its
alert had already caught (a copy of the code host, 50 hours old, `BackupStale` firing). That is the recovery point
this estate actually has: a day, not a promise.

**Recovery time: not measured.** Single datasets are restored every day. One secret store has been restored onto a
throwaway server and compared with the live one. The whole estate has never been rebuilt from nothing, so no honest
figure exists. The order below is written; it is not yet proven end to end.

## What must be carried

Nothing in the estate is irreplaceable except three secrets, because each one is needed before the thing that
would hold it is running:

| Secret | Why no backup can hold it |
|---|---|
| the password manager's master password | every other credential unlocks from it, the backup passwords among them |
| the configuration tool's own vault password | the configuration tool is what rebuilds the password manager |
| the off-site store's administrator credential | the password manager's own backup lives on that store |

**Where they are kept, by kind, not by place:** the first two in a message the owner sent to himself; the third in a
password manager outside the estate, in an account that does not depend on the estate. A copy inside the estate's
own password manager is allowed and is never the recovery copy: a credential inside the vault cannot restore the
vault.

**The backup passwords are not a fourth secret.** Each restic repository's password is an item in the password
manager, and it is also kept as a file on the off-site machine, in a share apart from the repositories, written by the
configuration run and compared with the password manager's copy by digest. The password manager's own backup opens
with that file, which the third carried secret reaches; everything else then comes back with secret one. So does the certificate authority's root key: it lives on no machine
(the CA's configuration asserts its absence on every run), only as an item in the password manager, written back to
mint a new intermediate during a rebuild and removed again. So does the secret store's unseal key. The drill below is
the core of this in miniature: a dataset comes back from the off-site copy plus a carried password, and does not
come back without it. It does not exercise the REST server, append-only, or two different passwords.

## Succession

**The successor is named, by the owner, in writing.** One person, a member of the family, is the one who takes over
if the owner cannot act. Their name is in the estate's own recovery document, not here.

**How the successor reaches the three secrets: the owner's devices and mailboxes.** The owner's ruling is that the
people who will act have access to his devices and can get into his mail when the time comes, so the path is the
devices plus every mailbox, not one account and not a sealed envelope. Two consequences are written down beside it:

- **One setting would break it.** If the outside password manager encrypts on the device, account access alone no
  longer opens it; the device's screen lock or a recovery PIN does. Whether that is on is recorded, not assumed.
- **It solves human succession, not agent succession.** An AI agent that rebuilds the estate cannot open a person's
  mail or password manager. A person has to hand it the three secrets.

**Break-glass, as a procedure.** When the owner is unavailable and something must be done now: the successor opens
the three secrets as above, and every act they take is written down as theirs, with the reason: on the estate's
ticket service while it runs, and in a plain file kept with the recovery notes when it does not. There is no standing
emergency account; the emergency is the successor holding the owner's keys.

What this path does not yet cover, stated so nobody assumes it does: one message holds two master secrets, so a
compromised mailbox exposes both; the message goes stale when a password changes, unless whoever changes it
rewrites it; the mail account, the outside password manager and the off-site provider each have their own second
factor and device passcode, which the successor must also reach; a provider may close an inactive account, and
nothing here gives anyone legal authority to act for an incapacitated owner; the successor may not be technical and
no engineer is named to help; and the successor has never walked the path.

## The rebuild order from nothing

The order follows credentials, not services:

1. **The router.** Nothing reaches anything without it. Its configuration is backed up nightly as a binary export.
   Restoring one replaces everything and reboots, with no dry run, and it has never been done. This is the one step
   with no proven procedure, and every other step depends on it.
2. **The controller**, a bare Debian machine with the configuration tool and its vault password. The configuration
   itself comes from a mirror of the code host kept on a cloud machine, or, if that is gone too, restored from the
   twin. On the controller the password manager is restored from the twin, with the repository password read from
   the off-site share that the third carried secret opens. The twin's TLS certificate chains to the estate's root,
   whose public certificate is in the configuration; the clock must be right first, or both TLS and the restore's
   signatures fail. If the twin abroad is itself gone, the copy at home is the source, and if both are, this
   document ends here.
3. **The password manager's real home.** It moves off the controller onto its own machine.
4. **DNS.** Names come before services.
5. **The code host.** The estate's own configuration needs a home inside the estate again.
6. **The certificate authority.** The root key is written back from the password manager, a fresh intermediate is
   issued, the key is removed, and every machine trusts the root before anything else is deployed.
7. **The secret store.** Its installation stops, by an explicit check, before initialising a new store, because
   initialising would write a new unseal key over the one every snapshot needs. Then the newest snapshot is restored and unsealed with the key from the password
   manager.
8. **The data stores, empty; then the data**, dataset by dataset, each from its newest snapshot.
9. **The applications**, from the configuration tool; then each application's environment, placed by its own step,
   then started.
10. **The read-back.** One command asks the configuration tool, in check mode, which declared privileges the new
    machines do not have; then the daily restore proof runs once by hand. The rebuild is finished when the first
    answers nothing and the second proves every dataset.

## The configuration, with example values

The home store and its twin, as restic sees them. The twin's REST server runs with `--append-only`:

```
RESTIC_REPOSITORY=rest:https://backup-home.home.arpa:8000/db-app
RESTIC_PASSWORD_FILE=/etc/restic/db-app.pass          # an item in the password manager, placed here

restic backup --host db1 --tag db-app --stdin-filename app.dump --stdin-from-command -- pg_dump --format=custom app

# the twin, made once with the home repository's chunker so a copy is deduplicated
restic init --repo rest:https://backup-abroad.example.net:8000/db-app --password-file /etc/restic/db-app-abroad.pass \
            --from-repo rest:https://backup-home.home.arpa:8000/db-app --from-password-file /etc/restic/db-app.pass \
            --copy-chunker-params
# nightly
restic copy --repo rest:https://backup-abroad.example.net:8000/db-app --password-file /etc/restic/db-app-abroad.pass \
            --from-repo rest:https://backup-home.home.arpa:8000/db-app --from-password-file /etc/restic/db-app.pass
```

`--stdin-from-command` (restic 0.17 and later) is restic's own way to back up a program's output. A shell pipe into `restic backup --stdin`
records a snapshot even when the dump fails half way; restic with `--stdin-from-command` fails with the dump.

The twin, run on the off-site machine:

```
rest-server --path /srv/restic --append-only --private-repos --tls --tls-cert /etc/rest/cert.pem --tls-key /etc/rest/key.pem
```

## The drill

[`drill-recovery.sh`](drill-recovery.sh) needs no credential and no network. It makes a dataset, backs it up to a
"home" repository, copies it to an "off-site" twin, keeps one copy of the repository password "carried" outside the
machine, and then deletes the machine and the home repository. It recovers from the twin with the carried password
alone, with an empty cache, and compares the result byte for byte. Needs restic (0.14 or later), sha256sum and
python3.

```
$ ./drill-recovery.sh
machine and home store removed; recovering from the off-site copy with the carried password
ok    the off-site copy holds the snapshot, read with the carried password
ok    the dataset is restored byte for byte from the off-site copy
all checks passed
```

With the carried password lost, exactly the two checks that need it must fail, and restic must say why (a wrong
password, not a damaged repository). That is the point of carrying it:

```
$ ARM=lostpassword ./drill-recovery.sh
...
FAIL  the off-site copy could not be read: {"message_type":"exit_error","code":12,"message":"Fatal: wrong password or no key found"}
FAIL  the dataset did not come back: Fatal: wrong password or no key found
ARM: exactly the off-site read and the restore failed, for a wrong password, as they must
```

## What is still open

- **The router restore has never been run.** Every step after it depends on it. Recovering from a failed restore
  needs someone at the router with a cable.
- **The whole procedure has never been executed,** so there is no recovery-time figure. It is a document, not yet a
  capability.
- **Six of twenty-two artefacts are present but not proven by a restore** in the daily job, the two router exports among
  them.
- **Restoring one tenant without the others** is not built: the copies are per store, and a store holds many tenants.
- **Agent succession.** An agent cannot open a person's mail; a person hands it the secrets.
- **Keeping by count on the twin** lets a flood of false snapshots push real ones out; keeping by time is not built.
- **The succession gaps** listed under break-glass.
