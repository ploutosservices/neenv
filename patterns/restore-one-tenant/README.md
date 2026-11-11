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
restore from, a fresh dump of the database as it is now, and where to write the plan.

```sh
restic dump <snapshot> /all_databases.sql > at.sql      # the backup to restore from
mariadb-dump --all-databases --single-transaction > now.sql   # the database now, dumped minutes ago
TR_MYSQL="mariadb -h scratch" TR_MYSQLDUMP="mariadb-dump -h scratch" \
  ./tenant-restore-modx.py --tenant <context> --at at.sql --now now.sql --out plan.sql
```

1. **It works on a scratch server only.** `TR_MYSQL` must reach a MariaDB whose user holds the `SHOW DATABASES`
   privilege (so nothing on the server is hidden from it) and that holds no database but the system ones and the
   script's own three (`tr_at`, `tr_now`, `tr_rehearse`). Pointed at the live server, which holds the real database,
   it stops before writing anything.
2. **It loads both dumps** into scratch databases. An all-databases dump is cut down to its header and the one
   database's section, streamed, so a large dump is never held in memory.
3. **It checks before writing a plan**, and each refusal names its code:

   | Code | Refused when |
   |---|---|
   | `tenant` | the key is not a context key, or is MODx's own `mgr` or `web` (in any case: the database compares keys without case) |
   | `incomplete` | a dump does not end in `-- Dump completed on <date>`: it was cut short, or made without its date |
   | `order` | the backup was dumped after the present: the two files are swapped |
   | `stale-now` | the present was dumped longer ago than `--max-now-age-hours` (24 by default, in the dump host's clock) |
   | `scratch` | the user may not see every database, or the server holds a database that is not scratch |
   | `no-database` | an all-databases dump does not contain the database |
   | `schema` | the two dumps' tables or columns differ (an upgrade happened between them) |
   | `engine` | a table the plan writes is not InnoDB, so the plan could not roll back as one |
   | `extras` | a table outside the tenant's set has a column that may hold page ids (an add-on's table) and was not acknowledged with `--declare <table>.<column>` |
   | `no-tenant` | the context is missing from either dump |
   | `empty` | the backup holds none of the tenant's pages: restoring would empty the tenant |
   | `collision` | a row id the backup gives the tenant belongs to another tenant now |
   | `orphan` | a row hangs off one of the backup's pages but is not the tenant's now, so it would be doubled |
   | `parent` | one of the tenant's pages sits under a page of another tenant |
   | `dependant` | something outside the tenant points at a page of the tenant's that the restore removes: another tenant's page under it, a context-resource row, a `site_start`, `error_page`, `unauthorized_page` or `site_unavailable_page` setting of another context or of the system, a symlink or weblink, a resource-list template-variable value, or a `[[~id]]` link in another page's content or summary |
   | `reference` | a template, template variable or group the tenant's rows name no longer exists |
   | `digest` | a comparison could not be made whole (too many rows for one digest) |

   Not checked: page ids written inside snippets, chunks, templates or element properties.
4. **It writes a plan**: one transaction. It opens with **guards** that abort it with nothing written unless the live
   database still holds, row for row, what the present dump held: the tenant's rows in every table of the set, the
   rows carrying the backup's page ids, the rows hanging off the tenant's pages, and none of the pointers above. Then
   it deletes the tenant's rows (template-variable values and group memberships through its pages, then the pages,
   the context settings and context-resource rows) and inserts the backup's, with their own ids, because pages link
   to each other by id. The inserts are taken from the dump tool with its own per-table `COMMIT` lines removed, so
   nothing commits before the end. Shared things (templates, snippets, users, access policies) are left alone: they
   are not one tenant's. The context's own settings come back as backed up, its `http_host` and `site_url` among
   them: check them before applying a backup from before a domain move.
5. **It rehearses the plan** on `tr_rehearse`, a copy of now, and refuses if any of these fails:

   | Code | Proved after the rehearsal |
   |---|---|
   | `apply` | the plan ran without an error (when it fails, the copy must be exactly as it was: the transaction rolled back) |
   | `outside-changed` | every table outside the tenant's set is unchanged |
   | `others-changed` | every other tenant's rows in the set are unchanged |
   | `tenant-differs` | the tenant's rows equal the backup's |

   Each comparison is a digest over every column of every row, so nothing is assumed from a row count.
6. **Only then is the plan written** (mode 0600, never over an existing file). The scratch copies hold tenant data,
   so they are dropped at the end whatever the outcome (`TR_KEEP_SCRATCH=1` keeps them for a look). Exit 0 means a
   plan was written, 1 a refusal (with the code, and no file), 2 that it could not run.

Applying the plan is a person's act: take a backup of the database first, then `mariadb <database> < plan.sql` on
the server that holds it, never with `--force` (the first error must end it). If the database changed since the
present dump, the guards stop it with nothing written: dump again and run the script again. For the same reason a
plan applies once; a second run stops on its guards and changes nothing.

## The drill

[`drill-tenant-restore.sh`](drill-tenant-restore.sh) needs Docker and runs two throwaway MariaDB containers, the
image pinned by digest. One holds a made-up database: ten of MODx 3's table definitions ([`schema.sql`](schema.sql):
`modx_context`, `modx_site_content`, `modx_site_tmplvar_contentvalues`, `modx_document_groups`,
`modx_context_setting`, `modx_context_resource`, `modx_site_templates`, `modx_site_tmplvars`,
`modx_documentgroup_names`, `modx_system_settings`), two tenants, alpha and beta ([`seed.sql`](seed.sql)), and what
happened after the backup ([`later.sql`](later.sql)): alpha lost a page and had one overwritten, beta added and
edited pages, and a system setting changed. The other container is the empty scratch server.

- **The restore.** The plan is applied to a copy of now. The drill's own queries then check that alpha is back as it
  was backed up, its later page gone, and that beta's later pages and the system setting are as they are now. Applied
  again, the plan must stop on its guards and change nothing.
- **The live guard.** The plan is applied to a copy of now in which alpha's page was edited again after the dump. It
  must stop on its guard and leave that database exactly as it was.
- **Twenty-seven refusals**, one or more per code above. Each must exit 1 with its code and leave no plan file, and
  no case may leave a scratch copy behind. Four of them plant a bug in a copy of the script: a delete that loses its
  tenant filter, a dropped insert, a write to a table outside the set, and a statement that fails halfway (after the
  deletes, before the inserts). For that last one the drill measures that the rehearsal copy is unchanged.
- **The arms.** Each check is switched off in a copy of the script, one at a time, and its case must then fail; so
  are the plan's guards and the clean-up. An armed copy that crashes counts as a failure of the drill, not as a red
  arm.

```
$ ./drill-tenant-restore.sh
cases (the script as committed):
  ok    restore
  ok    live
  ok    tenant
  ...
arms (one guard off; its case must fail):
  red   live (guard:live)
  ...
29 cases, 26 arms, 26 red, 0 failure(s)
```

`TR_DRILL_CASES_ONLY=1` runs the cases without the arms. Exit 0: every case as expected and every arm red. 1: not.
2: it could not run.

What the drill cannot show:

- a real tenant's size, and how long the load takes on a real dump;
- MODx's caches: after the plan is applied, clear the site's cache so pages are rebuilt from the database;
- the tenant's files (uploaded images and documents). They are a file tree, copied out of the backup by hand.

## What is still open

- **Files.** A tenant's own folder of assets is restored by hand from the snapshot.
- **No scheduled run.** Restoring a tenant is an operator's act on the owner's word; nothing runs it on a timer.
