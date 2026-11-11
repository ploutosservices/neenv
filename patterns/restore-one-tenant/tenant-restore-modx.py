#!/usr/bin/env python3
"""tenant-restore-modx.py — one MODx tenant (context) put back from a backup, the others untouched.

Published from a working script (neenv patterns/restore-one-tenant; README.md says how it is used). MODx keeps every tenant in ONE database, one context each. A restore of
the whole database rolls every tenant back to the backup's moment; this script restores one.

    tenant-restore-modx.py --tenant <context> --at <dump> --now <dump> --out <plan.sql>
                           [--database modx] [--prefix modx_] [--max-now-age-hours 24] [--declare <table>.<column>]...

  --at    the backup to restore FROM (e.g. `restic dump <snapshot> /all_databases.sql > at.sql`)
  --now   a FRESH dump of the database as it is now (refused when older than --max-now-age-hours)
  --out   where the plan goes; written ONLY when every check passed
  --declare  a column outside MODx's core that holds resource ids, acknowledged as NOT restored (else refused)

It loads both dumps into SCRATCH databases (tr_at, tr_now, tr_rehearse) on the server the client reaches, writes a
plan, applies the plan to tr_rehearse, and proves: every table outside the tenant's set is unchanged, every other
tenant's rows are unchanged, and the tenant's rows equal the backup's. It never writes to the live database:
applying the plan there is an operator's act.

The plan is ONE transaction. It begins with guards that abort it (SIGNAL, so nothing is written) unless the live
database still holds, row for row, what --now held for everything the plan touches or relies on.

The scratch server: TR_MYSQL (default "mariadb") and TR_MYSQLDUMP (default "mariadb-dump"), split like a shell
line, must reach a server where the user may see every database (the SHOW DATABASES privilege) and that holds no
database but the system ones and tr_* — so it cannot be the live server.

Exit 0 = plan written. 1 = refused ("REFUSED <code>: why"; no plan file). 2 = could not run.
"""
import argparse
import datetime
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
NOT_TENANTS = {"mgr", "web"}   # MODx's manager context and its default context are the system's, never a tenant's
# a column by one of these names, in a table outside the tenant's set, may hold resource ids (an extra's table)
REF_COLUMN = r"^(resource|resource_id|resourceid|content_id|contentid|document|document_id|doc_id|page_id)$"
# settings whose value is a resource id: one of them in another context, or in the system settings, pointing at a
# resource the restore removes, would break that site
ID_SETTINGS = ("site_start", "error_page", "unauthorized_page", "site_unavailable_page")
ON_SCRATCH = False
MYSQL = shlex.split(os.environ.get("TR_MYSQL", "mariadb"))
MYSQLDUMP = shlex.split(os.environ.get("TR_MYSQLDUMP", "mariadb-dump"))
GC_MAX = int(os.environ.get("TR_GROUP_CONCAT_MAX", "1073741824"))


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
    p = subprocess.run(cmd, input=f"SET SESSION group_concat_max_len = {GC_MAX};\n" + query,
                       capture_output=True, text=True)
    if p.returncode != 0:
        die(f"query failed ({p.stderr.strip()[:300]}): {query[:200]}")
    return [[None if c == "NULL" else c for c in line.split("\t")] for line in p.stdout.splitlines()]


def one(query, db=None):
    rows = sql(query, db)
    return rows[0][0] if rows else None


def completed_on(path):
    """The dump's 'Dump completed on' time; a dump without that last line was cut short (or has no date)."""
    with open(path, "rb") as f:
        f.seek(max(0, os.path.getsize(path) - 400))
        tail = f.read().decode("utf-8", "replace")
    m = re.search(r"-- Dump completed on (\d{4}-\d\d-\d\d)\s+(\d{1,2}:\d\d:\d\d)\s*$", tail)   # the hour is space-padded
    if not m: refuse("incomplete", f"{path} does not end in '-- Dump completed on <date>' (cut short, or dumped without its date)")  # guard:incomplete
    return datetime.datetime.strptime(f"{m.group(1)} {m.group(2)}", "%Y-%m-%d %H:%M:%S") if m else datetime.datetime.now()


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
            if line.startswith("/*M!999999\\- enable the sandbox mode"):
                continue   # MariaDB 11's first line, which other clients refuse
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


def ids(query):
    return [int(r[0]) for r in sql(query)]


def strlist(xs):
    """An SQL list of string literals (of digits and plain words only); an empty one matches nothing."""
    xs = [str(x) for x in xs]
    assert all(re.match(r"^[A-Za-z0-9_]+$", x) for x in xs)
    return "(" + (", ".join(f"'{x}'" for x in xs) or "NULL") + ")"


def inlist(xs):
    """An SQL list of integers; an empty one matches nothing."""
    return "(" + (", ".join(str(int(x)) for x in sorted(set(xs))) or "NULL") + ")"


def main():
    global ON_SCRATCH
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tenant", required=True)
    ap.add_argument("--at", required=True)
    ap.add_argument("--now", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--database", default="modx")
    ap.add_argument("--prefix", default="modx_")
    ap.add_argument("--max-now-age-hours", type=float, default=24.0)
    ap.add_argument("--declare", action="append", default=[])
    a = ap.parse_args()
    T, P = a.tenant, a.prefix

    for f in (a.at, a.now):
        if not os.path.isfile(f):
            die(f"no dump at {f}")
    if not re.match(r"^[A-Za-z0-9_]+$", a.database) or not re.match(r"^[A-Za-z0-9_]*$", P):
        die("--database and --prefix take letters, digits and _ only")
    if os.path.exists(a.out):
        die(f"{a.out} exists; a plan is never written over another")

    # MariaDB compares context keys without case, so 'MGR' is mgr: the refusal is case-blind too.
    if not TENANT_RE.match(T) or T.lower() in NOT_TENANTS: refuse("tenant", f"'{T}' is not a tenant's context key")  # guard:tenant

    # Both dumps whole, in order, and the present fresh — the plan's guards then hold the live database to it.
    at_on, now_on = completed_on(a.at), completed_on(a.now)
    if at_on > now_on: refuse("order", f"--at was dumped {at_on}, after --now {now_on}: the two are swapped")  # guard:order
    age = (datetime.datetime.now() - now_on).total_seconds() / 3600
    if age > a.max_now_age_hours: refuse("stale-now", f"--now was dumped {age:.1f} h ago (over {a.max_now_age_hours} h); dump the live database again")  # guard:stale-now

    # The scratch server: the user must be able to see every database (else a live server could look empty), and it
    # must hold nothing but scratch. Pointed at the live server, this stops before any write.
    priv = one("SELECT COUNT(*) FROM information_schema.USER_PRIVILEGES WHERE PRIVILEGE_TYPE IN ('SHOW DATABASES') AND GRANTEE = "
               "CONCAT('''', SUBSTRING_INDEX(CURRENT_USER(), '@', 1), '''@''', SUBSTRING_INDEX(CURRENT_USER(), '@', -1), '''')")
    if priv == "0": refuse("scratch", "the TR_MYSQL user lacks the SHOW DATABASES privilege, so the server's databases cannot all be seen")  # guard:scratch-priv
    held = {r[0] for r in sql("SHOW DATABASES")} - SYSTEM_DBS - set(SCRATCH)
    if held: refuse("scratch", f"the server TR_MYSQL reaches holds {sorted(held)}; use an empty scratch server")  # guard:scratch
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

    # The tenant's rows, table by table: a predicate on a row aliased {a} of that table, its resources read from the
    # site_content of database {src} ("`tr_now`." or "" for the live database the plan runs on).
    own = {
        "site_content": "{a}context_key = '{T}'",
        "context_setting": "{a}context_key = '{T}'",
        "context_resource": "{a}context_key = '{T}'",
        "site_tmplvar_contentvalues": "{a}contentid IN (SELECT id FROM {src}`{P}site_content` WHERE context_key = '{T}')",
        "document_groups": "{a}document IN (SELECT id FROM {src}`{P}site_content` WHERE context_key = '{T}')",
    }
    src = lambda db: f"`{db}`." if db else ""
    mine = lambda table, db, al="t.": own[table].format(T=T, P=P, src=src(db), a=al)

    at_tables, now_tables = tables("tr_at"), tables("tr_now")
    need = [P + "context", P + "site_templates", P + "site_tmplvars", P + "documentgroup_names", P + "system_settings"] \
        + [P + t for t in own]
    missing = [t for t in need if t not in at_tables or t not in now_tables]
    if missing: refuse("schema", f"tables missing from a dump: {missing}")  # guard:schema
    differ = [t for t in sorted(set(at_tables) | set(now_tables)) if columns("tr_at", t) != columns("tr_now", t)]
    if differ: refuse("schema", f"the two dumps' columns differ in {differ} (an upgrade between them)")  # guard:schema

    # One transaction only means something on a transactional engine.
    loose = [r[0] for r in sql(f"SELECT table_name FROM information_schema.tables WHERE table_schema = 'tr_now' "
                               f"AND table_name IN ({', '.join(repr(P + t) for t in own)}) AND engine <> 'InnoDB'")]
    if loose: refuse("engine", f"{loose} are not InnoDB in --now, so the plan could not roll back as one")  # guard:engine

    # A table outside the set with a column that may hold resource ids is an extra this script does not restore.
    declared = set(a.declare)
    extra = [f"{r[0]}.{r[1]}" for r in sql(
        f"SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'tr_now' "
        f"AND column_name REGEXP '{REF_COLUMN}' ORDER BY 1, 2") if r[0] not in {P + t for t in own}]
    undeclared = [e for e in extra if e not in declared]
    if undeclared: refuse("extras", f"{undeclared} may hold resource ids and are not restored; --declare each to accept that")  # guard:extras

    for db in ("tr_at", "tr_now"):
        if one(f"SELECT COUNT(*) FROM `{db}`.`{P}context` WHERE `key` = '{T}'") != "1": refuse("no-tenant", f"no context '{T}' in {db}")  # guard:no-tenant

    at_ids = ids(f"SELECT id FROM `tr_at`.`{P}site_content` WHERE context_key = '{T}'")
    now_ids = ids(f"SELECT id FROM `tr_now`.`{P}site_content` WHERE context_key = '{T}'")
    gone = sorted(set(now_ids) - set(at_ids))
    if not at_ids: refuse("empty", f"the backup holds no resource of '{T}'; restoring it would empty the tenant")  # guard:empty

    # An id the backup gives the tenant must not belong to anyone else now.
    for table in own:
        hit = one(f"SELECT COUNT(*) FROM `tr_at`.`{P}{table}` t JOIN `tr_now`.`{P}{table}` n ON n.id = t.id "
                  f"WHERE {mine(table, 'tr_at')} AND NOT ({mine(table, 'tr_now', 'n.')})") \
            if "id" in columns("tr_at", P + table) else "0"
        if hit != "0": refuse("collision", f"{hit} row id(s) of {P}{table} that the backup gives '{T}' belong to another tenant now")  # guard:collision

    # A row that hangs off one of the backup's resources but is not the tenant's now (an orphan) would be doubled.
    for table, col in (("site_tmplvar_contentvalues", "contentid"), ("document_groups", "document")):
        hit = one(f"SELECT COUNT(*) FROM `tr_now`.`{P}{table}` n WHERE n.{col} IN {inlist(at_ids)} AND n.{col} NOT IN {inlist(now_ids)}")
        if hit != "0": refuse("orphan", f"{hit} row(s) of {P}{table} hang off the backup's '{T}' resources but are not '{T}''s now")  # guard:orphan

    # The tenant's tree is its own: a parent outside it would tie the restore to another tenant's resource.
    hit = one(f"SELECT COUNT(*) FROM `tr_at`.`{P}site_content` t WHERE {mine('site_content', 'tr_at')} AND t.parent <> 0 "
              f"AND t.parent NOT IN {inlist(at_ids)}")
    if hit != "0": refuse("parent", f"{hit} of the backup's '{T}' resources have a parent outside '{T}'")  # guard:parent

    # What points, from outside the tenant, at a resource the restore removes: the same queries run here against
    # tr_now and inside the plan against the live database.
    def dependants(db):
        s, g = src(db), inlist(gone)
        links = "|".join(str(i) for i in gone) or "0"
        return [
            ("a parent", f"SELECT COUNT(*) FROM {s}`{P}site_content` WHERE context_key <> '{T}' AND parent IN {g}"),
            ("a context-resource row", f"SELECT COUNT(*) FROM {s}`{P}context_resource` WHERE context_key <> '{T}' AND resource IN {g}"),
            ("a context setting", f"SELECT COUNT(*) FROM {s}`{P}context_setting` WHERE context_key <> '{T}' "
                                  f"AND `key` IN {strlist(ID_SETTINGS)} AND value IN {strlist(gone)}"),
            ("a system setting", f"SELECT COUNT(*) FROM {s}`{P}system_settings` WHERE `key` IN {strlist(ID_SETTINGS)} "
                                 f"AND value IN {strlist(gone)}"),
            ("a symlink or weblink", f"SELECT COUNT(*) FROM {s}`{P}site_content` WHERE context_key <> '{T}' "
                                     f"AND class_key REGEXP '(SymLink|WebLink)$' AND TRIM(content) IN {strlist(gone)}"),
            ("a resource-list value", f"SELECT COUNT(*) FROM {s}`{P}site_tmplvar_contentvalues` v JOIN {s}`{P}site_tmplvars` tv ON tv.id = v.tmplvarid "
                                      f"WHERE tv.type = 'resourcelist' AND v.contentid NOT IN {inlist(now_ids)} AND TRIM(v.value) IN {strlist(gone)}"),
            ("a link in a page text", f"SELECT COUNT(*) FROM {s}`{P}site_content` WHERE context_key <> '{T}' "
                                        f"AND CONCAT(IFNULL(content, ''), ' ', IFNULL(introtext, '')) REGEXP '\\\\[\\\\[~({links})[^0-9]'"),
        ]
    if gone:
        for what, q in dependants("tr_now"):
            hit = one(q)
            if hit != "0": refuse("dependant", f"{hit} row(s) outside '{T}' point at a resource the restore removes, through {what}")  # guard:dependant

    # What the tenant's rows point at and do not own (templates, template variables, groups) must exist now.
    refs = [("site_content", "template", "site_templates", "t.template <> 0"),
            ("site_tmplvar_contentvalues", "tmplvarid", "site_tmplvars", "1"),
            ("document_groups", "document_group", "documentgroup_names", "1")]
    for table, col, target, cond in refs:
        hit = one(f"SELECT COUNT(*) FROM `tr_at`.`{P}{table}` t WHERE {mine(table, 'tr_at')} AND {cond} "
                  f"AND t.{col} NOT IN (SELECT id FROM `tr_now`.`{P}{target}`)")
        if hit != "0": refuse("reference", f"{hit} of the backup's '{T}' rows in {P}{table} name a {target} id that no longer exists")  # guard:reference

    # A digest of rows: their count and an MD5 over every column of every row, NULL when GROUP_CONCAT was cut short
    # (it stops at group_concat_max_len and max_allowed_packet), which the caller refuses.
    def digest_sql(db, table, where):
        cols = columns("tr_now", table)
        row = "MD5(CONCAT_WS(0x1f, " + ", ".join(f"IFNULL(HEX(t.`{c}`), 'N')" for c in cols) + "))"
        return (f"SELECT CONCAT(x.c, ':', IF(x.c = 0, '', IF(LENGTH(x.g) = 32 * x.c, MD5(x.g), 'CUT'))) FROM "
                f"(SELECT COUNT(*) AS c, GROUP_CONCAT({row} ORDER BY {row} SEPARATOR '') AS g FROM {src(db)}`{table}` t WHERE {where}) x")

    def digest(db, table, where):
        d = one(digest_sql(db, table, where))
        if d.endswith(":CUT"): refuse("digest", f"the digest of {table} in {db} was cut short (GROUP_CONCAT limit); too many rows to compare")  # guard:digest
        return d

    # The plan's opening guards: what the live database must still hold, as --now held it, for the plan to apply.
    held_now = []   # (label, digest query on the live database, expected digest from tr_now)
    for table in own:
        held_now.append((f"{P}{table}: the tenant's rows", digest_sql(None, P + table, mine(table, None)),
                         digest("tr_now", P + table, mine(table, "tr_now"))))
    touched = sorted(set(at_ids) | set(now_ids))
    held_now.append((f"{P}site_content: the rows with the backup's ids", digest_sql(None, P + "site_content", f"t.id IN {inlist(at_ids)}"),
                     digest("tr_now", P + "site_content", f"t.id IN {inlist(at_ids)}")))
    for table, col in (("site_tmplvar_contentvalues", "contentid"), ("document_groups", "document")):
        held_now.append((f"{P}{table}: the rows hanging off the tenant's resources", digest_sql(None, P + table, f"t.{col} IN {inlist(touched)}"),
                         digest("tr_now", P + table, f"t.{col} IN {inlist(touched)}")))
    guard_sql = []
    for label, q, want in held_now:
        guard_sql.append(f"  IF IFNULL(({q}), '') <> '{want}' THEN SIGNAL SQLSTATE '45000' "
                         f"SET MESSAGE_TEXT = 'tenant-restore: the live database differs from --now ({label.replace(chr(39), '')}); nothing written'; END IF;")
    if gone:
        for what, q in dependants(None):
            guard_sql.append(f"  IF ({q}) <> 0 THEN SIGNAL SQLSTATE '45000' "
                             f"SET MESSAGE_TEXT = 'tenant-restore: the live database differs from --now ({what} now points at a removed resource); nothing written'; END IF;")
    guards = "DELIMITER ;;\nBEGIN NOT ATOMIC\n" + "\n".join(guard_sql) + "\nEND;;\nDELIMITER ;\n"  # guard:live

    # The plan: the guards, then the dependants first, then the resources; the backup's rows with their own ids.
    deletes = [
        f"DELETE t FROM `{P}site_tmplvar_contentvalues` t JOIN `{P}site_content` c ON c.id = t.contentid WHERE c.context_key = '{T}';",
        f"DELETE t FROM `{P}document_groups` t JOIN `{P}site_content` c ON c.id = t.document WHERE c.context_key = '{T}';",
        f"DELETE FROM `{P}site_content` WHERE context_key = '{T}';",
        f"DELETE FROM `{P}context_setting` WHERE context_key = '{T}';",  # fault-point:widen
        f"DELETE FROM `{P}context_resource` WHERE context_key = '{T}';",
    ]
    inserts = []
    for table in ("site_content", "site_tmplvar_contentvalues", "document_groups", "context_setting", "context_resource"):
        p = subprocess.run(MYSQLDUMP + ["--no-create-info", "--compact", "--complete-insert", "--skip-extended-insert", "--hex-blob", "--skip-triggers",
                                        "--single-transaction", "--skip-lock-tables", "--default-character-set=utf8mb4", "--tz-utc",
                                        f"--where={mine(table, 'tr_at', '')}", "tr_at", P + table],
                           capture_output=True, text=True, encoding="utf-8", errors="surrogateescape")
        if p.returncode != 0:
            die(f"dumping {P}{table} from tr_at failed: {p.stderr.strip()[:300]}")
        # Only the INSERTs: the dump tool's own transaction lines (SET @@AUTOCOMMIT=0 ... COMMIT per table) would
        # commit the plan's deletes halfway; anything else it writes is refused rather than carried along.
        kept = []
        for line in p.stdout.splitlines():
            if line.startswith(f"INSERT INTO `{P}{table}` ("):
                kept.append(line)
            elif line.strip() == "" or re.match(r"^(set (@old_autocommit|@@autocommit|autocommit)\b[^;]*;|commit;|/\*.*\*/;?)$", line.strip(), re.I):
                continue
            else:
                die(f"the dump of {P}{table} carried a line that is not an INSERT: {line[:120]}")
        inserts.append("\n".join(kept) + ("\n" if kept else ""))  # fault-point:drop
    mid = ""  # fault-point:mid
    plan_tail = ""  # fault-point:outside
    sha = lambda f: hashlib.sha256(open(f, "rb").read()).hexdigest()
    plan = (f"-- tenant-restore-modx.py: put '{T}' back from {os.path.basename(a.at)} (dumped {at_on}, sha256 {sha(a.at)})\n"
            f"-- checked against {os.path.basename(a.now)} (dumped {now_on}, sha256 {sha(a.now)}); apply to the `{a.database}` database\n"
            f"-- with: mariadb {a.database} < this-file   (never with --force: the first error must end it, rolled back)\n"
            f"-- the context's own settings come back as backed up, http_host and site_url among them\n"
            f"SET NAMES utf8mb4;\nSET time_zone = '+00:00';\nSET SESSION group_concat_max_len = 1073741824;\n"
            "SET autocommit = 0;\nSTART TRANSACTION;\n" + guards + "\n".join(deletes) + "\n" + mid
            + "".join(inserts) + plan_tail + "COMMIT;\n")

    p = subprocess.run(MYSQL + ["tr_rehearse"], input=plan, text=True, capture_output=True,
                       encoding="utf-8", errors="surrogateescape")
    if p.returncode != 0:
        # a failure must leave the rehearsal copy exactly as it was: the plan is one transaction
        intact = all(digest("tr_now", t, "1") == digest("tr_rehearse", t, "1") for t in now_tables)
        refuse("apply", f"the plan failed on the rehearsal copy ({p.stderr.strip()[:240]}); rolled back: {'yes' if intact else 'NO'}")  # guard:apply

    outside = [t for t in now_tables if t not in {P + x for x in own}]
    changed = [t for t in outside if digest("tr_now", t, "1") != digest("tr_rehearse", t, "1")]
    if changed: refuse("outside-changed", f"the plan changed tables outside the tenant's set: {changed}")  # guard:outside-changed

    others = [P + t for t in own
              if digest("tr_now", P + t, f"NOT ({mine(t, 'tr_now')})") != digest("tr_rehearse", P + t, f"NOT ({mine(t, 'tr_rehearse')})")]
    if others: refuse("others-changed", f"the plan changed other tenants' rows in {others}")  # guard:others-changed

    differs = [P + t for t in own
               if digest("tr_at", P + t, mine(t, "tr_at")) != digest("tr_rehearse", P + t, mine(t, "tr_rehearse"))]
    if differs: refuse("tenant-differs", f"after the plan, '{T}''s rows differ from the backup's in {differs}")  # guard:tenant-differs

    d = os.path.dirname(os.path.abspath(a.out))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".plan-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write(plan)
        os.chmod(tmp, 0o600)
        os.link(tmp, a.out)   # refuses to replace a plan that appeared meanwhile
    finally:
        os.unlink(tmp)
    counts = {t: digest("tr_at", P + t, mine(t, "tr_at")).split(":")[0] for t in own}
    print(f"PLAN {a.out}: '{T}' from the backup — " + ", ".join(f"{P}{t} {n}" for t, n in counts.items())
          + f"; rehearsed: outside tables and other tenants unchanged, the tenant equal to the backup; "
          + f"{len(held_now)} digests and {len(dependants(None)) if gone else 0} dependant checks guard the live apply"
          + (f"; declared, not restored: {sorted(declared)}" if declared else ""))


def drop_scratch():
    """The scratch copies hold tenant data: dropped at the end, whatever happened (a refusal, a failure, a plan)."""
    held = {r[0] for r in sql("SHOW DATABASES")}
    for db in SCRATCH:
        if db in held:
            sql(f"DROP DATABASE `{db}`")


if __name__ == "__main__":
    rc = 0
    try:
        main()
    except Refused as e:
        print(e)
        rc = 1
    finally:
        try:
            if ON_SCRATCH and os.environ.get("TR_KEEP_SCRATCH") != "1":
                drop_scratch()  # guard:cleanup
        except SystemExit:
            pass
    sys.exit(rc)
