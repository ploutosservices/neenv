# Restoring one tenant without the others

## The problem

Several tenants often share one database. Here the content system, [MODx](https://modx.com/), keeps every tenant in
one MariaDB database, each tenant in its own *context*. The nightly backup copies the whole database server as one
dump into [restic](https://restic.net/).

Say one tenant's editor deletes a section on Monday and somebody notices on Thursday. The only restore on offer puts
the whole database back to Monday night. That throws away three days of every other tenant's pages to save one
tenant's, so in practice nobody restores and the section is typed in again.

This pattern restores **one** tenant from a backup and proves, before anyone applies it, that no other tenant's row
changed.

## Which stores this covers

| Store | One tenant is | Restored by |
|---|---|---|
| The content system (one database, a context per tenant) | its resources, their template-variable values and group memberships, its context settings | **this pattern** |
| A ledger with a tenant column in many tables | its rows | the same shape, built by the ledger's own owner |
| A file service with a library per person or group | a library | the file service's own history and trash |
| The sign-in door (one realm, tenants as groups) | its users and groups | the door's own export |

## How it works

[`tenant-restore-modx.py`](tenant-restore-modx.py) takes four things: the tenant (its context key), the backup to
restore from, a dump of the database as it is now, and where to write the plan.

```sh
restic dump <snapshot> /all_databases.sql > at.sql      # the backup to restore from
restic dump latest     /all_databases.sql > now.sql     # or a fresh dump of the database now
TR_MYSQL="mariadb -h scratch" TR_MYSQLDUMP="mariadb-dump -h scratch" \
  ./tenant-restore-modx.py --tenant <context> --at at.sql --now now.sql --out plan.sql
```

1. **It works on a scratch server only.** `TR_MYSQL` must reach a MariaDB that holds no database but the system ones
   and the script's own three (`tr_at`, `tr_now`, `tr_rehearse`). Pointed at the live server, which holds the real
   database, it stops before writing anything.
2. **It loads both dumps** into scratch databases. An all-databases dump is cut down to its header and the one
   database's section.
3. **It checks before writing a plan**, and each refusal names its code:

   | Code | Refused when |
   |---|---|
   | `tenant` | the key is not a context key, or is the manager's own context |
   | `scratch` | the server holds any database that is not scratch |
   | `no-database` | an all-databases dump does not contain the database |
   | `schema` | the two dumps' tables or columns differ (an upgrade happened between them) |
   | `no-tenant` | the context is missing from either dump |
   | `empty` | the backup holds none of the tenant's pages: restoring would empty the tenant |
   | `collision` | a row id the backup gives the tenant belongs to another tenant now |
   | `orphan` | a row hangs off one of the backup's pages but is not the tenant's now, so it would be doubled |
   | `parent` | one of the tenant's pages sits under a page of another tenant |
   | `dependant` | another tenant's page sits under, or points at, a page of the tenant's that the restore removes |
   | `reference` | a template, template variable or group the tenant's rows name no longer exists |

4. **It writes a plan**: one transaction that deletes the tenant's rows (template-variable values and group
   memberships through its pages, then the pages, the context settings and context-resource rows) and inserts the
   backup's, with their own ids, because pages link to each other by id. Shared things (templates, snippets, users,
   access policies) are left alone: they are not one tenant's.
5. **It rehearses the plan** on `tr_rehearse`, a copy of now, and refuses if any of these fails:

   | Code | Proved after the rehearsal |
   |---|---|
   | `apply` | the plan ran without an error |
   | `outside-changed` | every table outside the tenant's set is unchanged |
   | `others-changed` | every other tenant's rows in the set are unchanged |
   | `tenant-differs` | the tenant's rows equal the backup's |

   Each comparison is a digest over every column of every row, so nothing is assumed from a row count.
6. **Only then is the plan written** (mode 0600, never over an existing file). The scratch copies hold tenant data,
   so they are dropped at the end whatever the outcome (`TR_KEEP_SCRATCH=1` keeps them for a look). Exit 0 means a plan was written, 1 a
   refusal (with the code, and no file), 2 that it could not run.

Applying the plan is a person's act: take a backup of the database first, then `mariadb <database> < plan.sql` on
the server that holds it. Applied twice, the plan gives the same result.

## The drill

[`drill-tenant-restore.sh`](drill-tenant-restore.sh) needs Docker and runs two throwaway MariaDB containers, the
image pinned by digest. One holds a made-up database: MODx 3's table definitions ([`schema.sql`](schema.sql)), two
tenants, alpha and beta ([`seed.sql`](seed.sql)), and what happened after the backup ([`later.sql`](later.sql)):
alpha lost a page and had one overwritten, beta added and edited pages, and a system setting changed. The other
container is the empty scratch server.

- **One restore case.** The plan is applied twice to a copy of now. The drill's own queries then check that alpha is
  back as it was backed up, its later page gone, and that beta's later pages and the system setting are as they
  are now.
- **Sixteen refusal cases**, one per code above (two for `tenant`). Each must exit 1 with its code and leave no plan
  file, and no case may leave a scratch copy behind. Three of them plant a bug in a copy of the script (a delete that loses its tenant filter, a dropped insert,
  a write to a table outside the set) so each rehearsal check is shown catching a broken plan, and one plants a
  statement that fails.
- **The arms.** Each check is switched off in a copy of the script, one at a time, and its case must then fail; so
  is the clean-up, which must then fail the restore case. An armed copy that crashes counts as a failure of the
  drill, not as a red arm.

```
$ ./drill-tenant-restore.sh
cases (the script as committed):
  ok    restore
  ok    tenant
  ...
arms (one guard off; its case must fail):
  red   tenant
  ...
17 cases, 16 arms, 16 red, 0 failure(s)
```

`TR_DRILL_CASES_ONLY=1` runs the cases without the arms. Exit 0: every case as expected and every arm red. 1: not.
2: it could not run.

What the drill cannot show:

- a real tenant's size, and how long the load takes on a real dump;
- links written inside a page's text (`[[~id]]`) to a page the restore removes: they are text, not columns;
- MODx's caches: after the plan is applied, clear the site's cache so pages are rebuilt from the database;
- the tenant's files (uploaded images and documents). They are a file tree, copied out of the backup by hand.

## What is still open

- **Files.** A tenant's own folder of assets is restored by hand from the snapshot.
- **No scheduled run.** Restoring a tenant is an operator's act on the owner's word; nothing runs it on a timer.
