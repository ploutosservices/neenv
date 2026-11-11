#!/usr/bin/env python3
"""tenant-restore-modx.py — one MODx tenant (context) put back from a backup, the others untouched.

Published from a working script (neenv patterns/restore-one-tenant; README.md says how it is used). MODx keeps every tenant in ONE database, one context each. A restore of
the whole database rolls every tenant back to the backup's moment; this script restores one.

    tenant-restore-modx.py --tenant <context> --at <dump> --now <dump> --out <plan.sql> [--database modx] [--prefix modx_]

  --at    the backup to restore FROM (e.g. `restic dump <snapshot> /all_databases.sql > at.sql`)
  --now   a dump of the database as it is now (the newest snapshot, or a fresh dump)
  --out   where the plan goes; written ONLY when every check passed

It loads both dumps into SCRATCH databases (tr_at, tr_now, tr_rehearse) on the server the client reaches, writes a
plan (one transaction: delete the tenant's rows, insert the backup's), applies the plan to tr_rehearse, and proves:
every table outside the tenant's set is unchanged, every other tenant's rows are unchanged, and the tenant's rows
equal the backup's. It never writes to the live database: applying the plan there is an operator's act.

The scratch server: TR_MYSQL (default "mariadb") and TR_MYSQLDUMP (default "mariadb-dump"), split like a shell
line, must reach a server that holds NO database but the system ones and tr_* — so it cannot be the live server.

Exit 0 = plan written. 1 = refused ("REFUSED <code>: why"; no plan file). 2 = could not run.
"""
import argparse
import hashlib
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

SYSTEM_DBS = {"information_schema", "mysql", "performance_schema", "sys"}
SCRATCH = ("tr_at", "tr_now", "tr_rehearse")
TENANT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")
NOT_TENANTS = {"mgr"}   # MODx's manager context is the system's, never a tenant's
ON_SCRATCH = False
MYSQL = shlex.split(os.environ.get("TR_MYSQL", "mariadb"))
MYSQLDUMP = shlex.split(os.environ.get("TR_MYSQLDUMP", "mariadb-dump"))


class Refused(Exception):
    pass


def refuse(code, why):
    raise Refused(f"REFUSED {code}: {why}")


def die(why):
    print(f"cannot run: {why}", file=sys.stderr)
    sys.exit(2)


def sql(query, db=None):
    """Rows of one query on the scratch server, as lists of strings (NULL as None)."""
    cmd = MYSQL + ["--batch", "--skip-column-names", "--raw"] + ([db] if db else [])
    p = subprocess.run(cmd, input="SET SESSION group_concat_max_len = 1073741824;\n" + query,
                       capture_output=True, text=True)
    if p.returncode != 0:
        die(f"query failed ({p.stderr.strip()[:300]}): {query[:200]}")
    return [[None if c == "NULL" else c for c in line.split("\t")] for line in p.stdout.splitlines()]


def one(query, db=None):
    rows = sql(query, db)
    return rows[0][0] if rows else None


def section(path, database, out):
    """Writes to <out> the dump's header (charset and session settings) and the one database's statements, streamed
    (a dump of every database can be large). A dump of one database (no "-- Current Database:" lines) is taken whole;
    an all-databases dump without this database is refused."""
    state, marked, body = "head", False, 0
    want = f"-- Current Database: `{database}`"
    with open(path, encoding="utf-8", errors="surrogateescape") as f, \
         open(out, "w", encoding="utf-8", errors="surrogateescape") as o:
        for line in f:
            if line.startswith("-- Current Database: "):
                marked = True
                state = "in" if line.rstrip("\n") == want else "out"
                continue
            if state == "head" or (state == "in" and not re.match(r"^(CREATE DATABASE|USE )", line)):
                o.write(line)
                body += state == "in"
    if marked and not body: refuse("no-database", f"{path} is an all-databases dump with no `{database}` in it")  # guard:no-database


def load(part, into):
    sql(f"DROP DATABASE IF EXISTS `{into}`; CREATE DATABASE `{into}` CHARACTER SET utf8mb4;")
    with open(part, "rb") as f:
        p = subprocess.run(MYSQL + [into], stdin=f, capture_output=True)
    if p.returncode != 0:
        die(f"loading into {into} failed: {p.stderr.decode(errors='replace').strip()[:300]}")


def columns(db, table):
    return [r[0] for r in sql(f"SELECT column_name FROM information_schema.columns WHERE table_schema = '{db}' "
                              f"AND table_name = '{table}' ORDER BY ordinal_position")]


def tables(db):
    return [r[0] for r in sql(f"SELECT table_name FROM information_schema.tables WHERE table_schema = '{db}' "
                              "AND table_type = 'BASE TABLE' ORDER BY table_name")]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tenant", required=True)
    ap.add_argument("--at", required=True)
    ap.add_argument("--now", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--database", default="modx")
    ap.add_argument("--prefix", default="modx_")
    a = ap.parse_args()
    T, P = a.tenant, a.prefix

    for f in (a.at, a.now):
        if not os.path.isfile(f):
            die(f"no dump at {f}")
    if not re.match(r"^[A-Za-z0-9_]+$", a.database) or not re.match(r"^[A-Za-z0-9_]*$", P):
        die("--database and --prefix take letters, digits and _ only")
    if os.path.exists(a.out):
        die(f"{a.out} exists; a plan is never written over another")

    if not TENANT_RE.match(T) or T in NOT_TENANTS: refuse("tenant", f"'{T}' is not a tenant's context key")  # guard:tenant

    # The scratch server holds nothing but scratch: pointed at the live server, this stops before any write.
    held = {r[0] for r in sql("SHOW DATABASES")} - SYSTEM_DBS - set(SCRATCH)
    if held: refuse("scratch", f"the server TR_MYSQL reaches holds {sorted(held)}; use an empty scratch server")  # guard:scratch
    global ON_SCRATCH
    ON_SCRATCH = True   # only now may the end drop tr_* (never on a server this script refused to use)

    work = tempfile.mkdtemp(prefix="tenant-restore-")
    try:
        os.chmod(work, 0o700)
        section(a.at, a.database, f"{work}/at.sql")
        section(a.now, a.database, f"{work}/now.sql")
        load(f"{work}/at.sql", "tr_at")
        load(f"{work}/now.sql", "tr_now")
        load(f"{work}/now.sql", "tr_rehearse")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    # the tenant's rows, table by table: a predicate on a row `t` of that table, inside database {db}
    own = {
        "site_content": "{a}context_key = '{T}'",
        "context_setting": "{a}context_key = '{T}'",
        "context_resource": "{a}context_key = '{T}'",
        "site_tmplvar_contentvalues": "{a}contentid IN (SELECT id FROM `{db}`.`{P}site_content` WHERE context_key = '{T}')",
        "document_groups": "{a}document IN (SELECT id FROM `{db}`.`{P}site_content` WHERE context_key = '{T}')",
    }
    mine = lambda table, db, a="t.": own[table].format(T=T, P=P, db=db, a=a)

    at_tables, now_tables = tables("tr_at"), tables("tr_now")
    need = [P + "context", P + "site_templates", P + "site_tmplvars", P + "documentgroup_names"] + [P + t for t in own]
    missing = [t for t in need if t not in at_tables or t not in now_tables]
    if missing: refuse("schema", f"tables missing from a dump: {missing}")  # guard:schema
    differ = [t for t in sorted(set(at_tables) | set(now_tables)) if columns("tr_at", t) != columns("tr_now", t)]
    if differ: refuse("schema", f"the two dumps' columns differ in {differ} (an upgrade between them)")  # guard:schema

    for db in ("tr_at", "tr_now"):
        if one(f"SELECT COUNT(*) FROM `{db}`.`{P}context` WHERE `key` = '{T}'") != "1": refuse("no-tenant", f"no context '{T}' in {db}")  # guard:no-tenant

    n_at = int(one(f"SELECT COUNT(*) FROM `tr_at`.`{P}site_content` t WHERE {mine('site_content', 'tr_at')}"))
    if n_at == 0: refuse("empty", f"the backup holds no resource of '{T}'; restoring it would empty the tenant")  # guard:empty

    # An id the backup gives the tenant must not belong to anyone else now.
    for table in own:
        hit = one(f"SELECT COUNT(*) FROM `tr_at`.`{P}{table}` t JOIN `tr_now`.`{P}{table}` n ON n.id = t.id "
                  f"WHERE {mine(table, 'tr_at')} AND NOT ({mine(table, 'tr_now', 'n.')})") \
            if "id" in columns("tr_at", P + table) else "0"
        if hit != "0": refuse("collision", f"{hit} row id(s) of {P}{table} that the backup gives '{T}' belong to another tenant now")  # guard:collision

    # A row that hangs off one of the backup's resources but is not the tenant's now (an orphan) would be doubled.
    for table, col in (("site_tmplvar_contentvalues", "contentid"), ("document_groups", "document")):
        hit = one(f"SELECT COUNT(*) FROM `tr_now`.`{P}{table}` n WHERE n.{col} IN (SELECT id FROM `tr_at`.`{P}site_content` "
                  f"WHERE context_key = '{T}') AND n.{col} NOT IN (SELECT id FROM `tr_now`.`{P}site_content` WHERE context_key = '{T}')")
        if hit != "0": refuse("orphan", f"{hit} row(s) of {P}{table} hang off the backup's '{T}' resources but are not '{T}''s now")  # guard:orphan

    # The tenant's tree is its own: a parent outside it would tie the restore to another tenant's resource.
    hit = one(f"SELECT COUNT(*) FROM `tr_at`.`{P}site_content` t WHERE {mine('site_content', 'tr_at')} AND t.parent <> 0 "
              f"AND t.parent NOT IN (SELECT id FROM `tr_at`.`{P}site_content` WHERE context_key = '{T}')")
    if hit != "0": refuse("parent", f"{hit} of the backup's '{T}' resources have a parent outside '{T}'")  # guard:parent

    # Another tenant's row that points at one of the tenant's resources the plan deletes and does not put back.
    gone = (f"SELECT id FROM `tr_now`.`{P}site_content` WHERE context_key = '{T}' AND id NOT IN "
            f"(SELECT id FROM `tr_at`.`{P}site_content` WHERE context_key = '{T}')")
    hit = int(one(f"SELECT COUNT(*) FROM `tr_now`.`{P}site_content` WHERE context_key <> '{T}' AND parent IN ({gone})")) \
        + int(one(f"SELECT COUNT(*) FROM `tr_now`.`{P}context_resource` WHERE context_key <> '{T}' AND resource IN ({gone})"))
    if hit: refuse("dependant", f"{hit} row(s) of other tenants point at '{T}' resources the restore removes")  # guard:dependant

    # What the tenant's rows point at and do not own (templates, template variables, groups) must exist now.
    refs = [("site_content", "template", "site_templates", "t.template <> 0"),
            ("site_tmplvar_contentvalues", "tmplvarid", "site_tmplvars", "1"),
            ("document_groups", "document_group", "documentgroup_names", "1")]
    for table, col, target, cond in refs:
        hit = one(f"SELECT COUNT(*) FROM `tr_at`.`{P}{table}` t WHERE {mine(table, 'tr_at')} AND {cond} "
                  f"AND t.{col} NOT IN (SELECT id FROM `tr_now`.`{P}{target}`)")
        if hit != "0": refuse("reference", f"{hit} of the backup's '{T}' rows in {P}{table} name a {target} id that no longer exists")  # guard:reference

    # The plan: one transaction; the dependants first, then the resources; the backup's rows with their own ids.
    deletes = [
        f"DELETE t FROM `{P}site_tmplvar_contentvalues` t JOIN `{P}site_content` c ON c.id = t.contentid WHERE c.context_key = '{T}';",
        f"DELETE t FROM `{P}document_groups` t JOIN `{P}site_content` c ON c.id = t.document WHERE c.context_key = '{T}';",
        f"DELETE FROM `{P}site_content` WHERE context_key = '{T}';",
        f"DELETE FROM `{P}context_setting` WHERE context_key = '{T}';",  # fault-point:widen
        f"DELETE FROM `{P}context_resource` WHERE context_key = '{T}';",
    ]
    inserts = []
    for table in ("site_content", "site_tmplvar_contentvalues", "document_groups", "context_setting", "context_resource"):
        where = mine(table, "tr_at", "")
        p = subprocess.run(MYSQLDUMP + ["--no-create-info", "--compact", "--complete-insert", "--hex-blob", "--skip-triggers",
                                        "--single-transaction", "--skip-lock-tables", "--default-character-set=utf8mb4", "--tz-utc",
                                        f"--where={where}", "tr_at", P + table],
                           capture_output=True, text=True, encoding="utf-8", errors="surrogateescape")
        if p.returncode != 0:
            die(f"dumping {P}{table} from tr_at failed: {p.stderr.strip()[:300]}")
        inserts.append(p.stdout)  # fault-point:drop
    plan_tail = ""  # fault-point:outside
    digest = lambda f: hashlib.sha256(open(f, "rb").read()).hexdigest()
    plan = (f"-- tenant-restore-modx.py: put '{T}' back from {os.path.basename(a.at)} (sha256 {digest(a.at)})\n"
            f"-- checked against {os.path.basename(a.now)} (sha256 {digest(a.now)}); apply to the `{a.database}` database\n"
            "SET NAMES utf8mb4;\nSET time_zone = '+00:00';\nSET autocommit = 0;\nSTART TRANSACTION;\n" + "\n".join(deletes) + "\n"
            + "".join(inserts) + plan_tail + "COMMIT;\n")

    p = subprocess.run(MYSQL + ["tr_rehearse"], input=plan, text=True, capture_output=True,
                       encoding="utf-8", errors="surrogateescape")
    if p.returncode != 0: refuse("apply", f"the plan failed on the rehearsal copy: {p.stderr.strip()[:300]}")  # guard:apply

    def digest_rows(db, table, where):
        cols = columns(db, table)
        row = "CONCAT_WS(0x1f, " + ", ".join(f"IFNULL(HEX(t.`{c}`), 'N')" for c in cols) + ")"
        r = sql(f"SELECT COUNT(*), IFNULL(MD5(GROUP_CONCAT(MD5({row}) ORDER BY MD5({row}) SEPARATOR '')), '') "
                f"FROM `{db}`.`{table}` t WHERE {where}")
        return tuple(r[0])

    outside = [t for t in now_tables if t not in {P + x for x in own}]
    changed = [t for t in outside if digest_rows("tr_now", t, "1") != digest_rows("tr_rehearse", t, "1")]
    if changed: refuse("outside-changed", f"the plan changed tables outside the tenant's set: {changed}")  # guard:outside-changed

    others = [P + t for t in own
              if digest_rows("tr_now", P + t, f"NOT ({mine(t, 'tr_now')})") != digest_rows("tr_rehearse", P + t, f"NOT ({mine(t, 'tr_rehearse')})")]
    if others: refuse("others-changed", f"the plan changed other tenants' rows in {others}")  # guard:others-changed

    differs = [P + t for t in own
               if digest_rows("tr_at", P + t, mine(t, "tr_at")) != digest_rows("tr_rehearse", P + t, mine(t, "tr_rehearse"))]
    if differs: refuse("tenant-differs", f"after the plan, '{T}''s rows differ from the backup's in {differs}")  # guard:tenant-differs

    d = os.path.dirname(os.path.abspath(a.out))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".plan-")
    with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(plan)
    os.chmod(tmp, 0o600)
    os.link(tmp, a.out)   # refuses to replace a plan that appeared meanwhile
    os.unlink(tmp)
    counts = {t: digest_rows("tr_at", P + t, mine(t, "tr_at"))[0] for t in own}
    print(f"PLAN {a.out}: '{T}' from the backup — " + ", ".join(f"{P}{t} {n}" for t, n in counts.items())
          + "; rehearsed: outside tables and other tenants unchanged, the tenant equal to the backup")


def drop_scratch():
    """The scratch copies hold tenant data: dropped at the end, whatever happened (a refusal, a failure, a plan)."""
    held = {r[0] for r in sql("SHOW DATABASES")}
    for db in SCRATCH:
        if db in held:
            sql(f"DROP DATABASE `{db}`")


if __name__ == "__main__":
    try:
        main()
    except Refused as e:
        print(e)
        rc = 1
    else:
        rc = 0
    finally:
        try:
            if ON_SCRATCH and os.environ.get("TR_KEEP_SCRATCH") != "1":
                drop_scratch()  # guard:cleanup
        except SystemExit:
            pass
    sys.exit(rc)
