# Retention and a tenant's departure

## The problem

A tenant outside the family will one day leave. On that day three questions need answers that were decided
beforehand: what the tenant gets back, when its data stops existing here, and how long copies of it outlive the
live data. Without a written answer the data stays for ever by default, in the live stores and in every backup,
and nobody can say when it would have gone.

## What runs here

**Three periods, set by the owner.**

| Step | When | What |
|---|---|---|
| Notice | day 0 | The tenant says it is leaving. The date is written down. |
| Export | by day 30 | The tenant gets a full export of its data: each application's rows for that tenant, and its files, in a format it can read without us. |
| Deletion | by day 60 (30 days after the export) | The tenant's live data is deleted from every application and every store. |
| Backups | on the normal schedule, with two exceptions below | Snapshots that also hold other tenants age out under the usual keep policy. |

**Why shared backups are not edited.** A backup is encrypted, deduplicated snapshots (restic). Removing one tenant
from snapshots that also hold everyone else means rewriting them, which breaks the property that makes them worth
having: an old snapshot is exactly what was there. So the tenant's data leaves those backups when the last snapshot
that holds it is forgotten.

**How long that is.** The keep policy holds 7 daily, 5 weekly and 12 monthly snapshots in the first copy, and
7 daily, 8 weekly and 24 monthly in the off-site copy. Restic counts those months backwards from a group's newest
snapshot, among months that have a snapshot, not by the calendar. While the nightly backups keep running, a tenant
deleted in a given month is gone from the first copy 12 months later and from the off-site copy 24 months later.
That window is what the tenant is told at notice. It is not zero.

**Exception 1: a group with no new snapshots never ages out.** Restic groups snapshots by host and path, and
prunes each group against its own newest snapshot. A tree or a store that held only this tenant, and so stops
being backed up when the tenant is deleted, keeps its last 12 (or 24) monthly snapshots for ever. So the
departure lists the snapshot groups that hold only the tenant and forgets them by name, in both copies:
`restic forget --prune --host <host> --path <path> <every id in that group>`.

**Exception 2: a snapshot kept for ever.** The first copy also keeps every snapshot tagged `final`: a store's last
copy before the store itself is dropped, tagged by whoever drops it. A departure must not leave the tenant there.
The departure check lists every `final` snapshot and refuses the departure if one holds the tenant. That snapshot
is then rewritten without the tenant, which is the one place a backup is edited:
`restic rewrite --forget --exclude <the tenant's stored path> <id>`, then `restic prune`. The rewrite keeps the
tag, so the store's last copy survives without the tenant.

**What the check looks for.** Each application names the path pattern its backups store a tenant under (a
per-tenant dump file, a per-tenant folder). The check greps `restic ls` of each snapshot for that pattern; an
application whose backups cannot separate one tenant falls under the window above only.

## The configuration, with example values

The keep policy, as each nightly prune runs it:

```
restic forget --prune --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-tag final   # first copy
restic forget --prune --keep-daily 7 --keep-weekly 8 --keep-monthly 24                    # off-site copy
```

The departure record, one per tenant, written at notice:

```
tenant:        acme
notice:        2027-03-01
export_by:     2027-03-31
delete_by:     2027-04-30
backups_gone:  first copy 2028-04, off-site 2029-04 (while the nightly backups keep running)
own_groups:    host acme-files: forgotten in both copies on delete_by
final_check:   no final snapshot holds acme (run on delete_by; rewritten where one did)
```

## The drill

[`drill-retention.sh`](drill-retention.sh) gives a scratch restic repository one snapshot a month. The tenant's
file is in the application's snapshots up to its deletion month and in none after; it also has a tree of its own,
backed up only while it exists. The drill applies the keep policy and requires:

1. the dates come out as above (notice + 30, export + 30);
2. 11 months after the deletion month, a snapshot that is not `final` still holds the tenant (the window is real);
3. 12 months after the deletion month, no snapshot holds it (the window closes exactly there);
4. the tenant's own group still holds its snapshots after the window, and the departure step's forget empties it;
5. a `final` snapshot holding the tenant is refused, and after the rewrite and prune the check passes with the
   `final` copy still there.

`POLICY=offsite` runs it with the off-site policy (24 months; case 5 is skipped, since that copy keeps no tag for
ever). Three arms show each check failing as designed: `ARM=nokeep` runs no prune and `ARM=finaltag` plants a
kept-for-ever copy without the check, and in each only case 3 fails; `ARM=nogroup` skips the departure step's
forget, and only case 4 fails. Only the monthly rule is drilled: with one snapshot a month, the daily and weekly
rules keep nothing the monthly rule does not. Exit 0 proved, 1 not, 2 could not run.

## What is still open

- **No departure verb yet.** Each application exports and deletes a tenant's rows its own way; none has a single
  command for it, and none has named its per-tenant backup path yet. The first tenant to leave writes them, one
  application at a time, and each is drilled like the [one-tenant restore](../restore-one-tenant/README.md).
- **Logs.** Central logs keep their own period; a tenant's name in a log line ages out with the log, not with the
  departure.
