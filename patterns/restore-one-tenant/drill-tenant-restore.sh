#!/bin/bash
# drill-tenant-restore.sh — one MODx tenant restored, the others untouched, on throwaway containers
# (neenv patterns/restore-one-tenant).   ./drill-tenant-restore.sh   needs Docker (docker, or sudo -n docker)
#
# Two MariaDB containers (the image pinned by digest): SRC holds a made-up `modx` database with two tenants (seed.sql on
# MODx 3's table definitions, schema.sql); its dumps are the backup (at) and, after later.sql, the present (now).
# SCR is the empty scratch server scripts/tenant-restore-modx.py works on. Each case runs the script unchanged and must
# end as named: a plan that, applied twice to a copy of `now`, gives alpha back as backed up and keeps beta's later work
# and the system setting; or a refusal with its code and no plan file. Then each guard is disabled in a copy of the
# script, one at a time, and the case named for that guard must FAIL. No real database is touched.
# TR_DRILL_CASES_ONLY=1 skips the arms. Exit 0 = every case as expected and every arm red; 1 = not; 2 = could not run.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); SCRIPT=${TR_SCRIPT:-$HERE/tenant-restore-modx.py}
dk() { if docker info >/dev/null 2>&1; then docker "$@"; else sudo -n docker "$@"; fi; }
dk info >/dev/null 2>&1 || { echo "cannot run: no Docker (docker, or sudo -n docker)"; exit 2; }
IMG=mariadb@sha256:79d59758afc91b89b120b0a8904d637f5a3b3e1c4900f29b740d6d46c72fef68   # MariaDB 11.8.9
SRC=tr-src-$$; SCR=tr-scr-$$; W=$(mktemp -d)
trap 'dk rm -f $SRC $SCR >/dev/null 2>&1; rm -rf "$W"' EXIT
for c in $SRC $SCR; do
  dk run -d --name $c -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 $IMG >/dev/null || { echo "cannot run: $c did not start"; exit 2; }
done
# the image starts a temporary server to initialise, then the real one: ready once its log says so for the second time
ready() { [ "$(dk logs $1 2>&1 | grep -c 'ready for connections')" -ge 2 ] && dk exec $1 mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1; }
for c in $SRC $SCR; do for i in $(seq 1 60); do ready $c && break; sleep 1; done; ready $c || { echo "cannot run: $c not ready"; exit 2; }; done
q() { dk exec -i $SRC mariadb -uroot --batch --skip-column-names "$@"; }                 # the source server
dump() { dk exec $SRC mariadb-dump -uroot --all-databases --single-transaction --skip-dump-date; }  # what the backup job runs

# The backup's moment and the present, plus the variants each case needs (each a fresh source state, dumped).
base() { q -e 'DROP DATABASE IF EXISTS modx; DROP DATABASE IF EXISTS other; CREATE DATABASE modx; CREATE DATABASE other;
               CREATE TABLE other.t (id int primary key); INSERT INTO other.t VALUES (1);' \
         && q modx < "$HERE/schema.sql" && q modx < "$HERE/seed.sql"; }
mk() {  # mk <file> <extra sql before the dump> [later]
  base || { echo "cannot run: the seed did not load"; exit 2; }
  [ "${3:-}" = later ] && { q modx < "$HERE/later.sql" || { echo "cannot run: later.sql did not load"; exit 2; }; }
  [ -n "$2" ] && { q modx -e "$2" || { echo "cannot run: variant $1 did not load"; exit 2; }; }
  dump > "$W/$1" || { echo "cannot run: dump $1"; exit 2; }
  grep -q 'Dump completed' "$W/$1" || { echo "cannot run: dump $1 incomplete"; exit 2; }
}
mk at.sql ""
mk now.sql "" later
mk at-empty.sql "DELETE FROM modx_site_content WHERE context_key = 'alpha'"
mk at-parent.sql "UPDATE modx_site_content SET parent = 20 WHERE id = 12"
mk now-notenant.sql "DELETE FROM modx_context WHERE \`key\` = 'alpha'" later
mk now-collision.sql "INSERT INTO modx_site_content (id, pagetitle, description, alias, content, template, context_key) VALUES (12, 'Beta took 12', '', 'b12', 'b', 2, 'beta')" later
mk now-orphan.sql "INSERT INTO modx_site_tmplvar_contentvalues (id, tmplvarid, contentid, value) VALUES (9, 1, 12, 'orphan')" later
mk now-reference.sql "DELETE FROM modx_site_templates WHERE id = 2" later
mk now-dependant.sql "INSERT INTO modx_site_content (id, pagetitle, description, alias, parent, content, template, context_key) VALUES (23, 'Beta under alpha junk', '', 'b23', 13, 'b', 2, 'beta')" later
mk now-schema.sql "ALTER TABLE modx_site_content ADD COLUMN extra int NOT NULL DEFAULT 0" later
dk exec $SRC mariadb-dump -uroot --databases other --skip-dump-date > "$W/at-nomodx.sql" || { echo "cannot run: dump nomodx"; exit 2; }

export TR_MYSQL="$W/m-scr" TR_MYSQLDUMP="$W/d-scr"
# client wrappers: docker exec into a container (through sudo -n when needed), the scratch one by default
for pair in "scr $SCR" "src $SRC"; do set -- $pair
  printf '#!/bin/bash\nif docker info >/dev/null 2>&1; then D=docker; else D="sudo -n docker"; fi\nexec $D exec -i %s mariadb -uroot "$@"\n' $2 > "$W/m-$1"
  printf '#!/bin/bash\nif docker info >/dev/null 2>&1; then D=docker; else D="sudo -n docker"; fi\nexec $D exec -i %s mariadb-dump -uroot "$@"\n' $2 > "$W/d-$1"
done
chmod +x "$W"/m-* "$W"/d-*

# The plan, applied to a fresh copy of `now` on the source server (twice: a second run changes nothing), gives alpha
# back as backed up and keeps everything that is not alpha's — measured here by the drill, not by the script.
proven() {  # proven <plan>
  q -e 'DROP DATABASE IF EXISTS modx; CREATE DATABASE modx' && sed -n '/^-- Current Database: `modx`/,/^-- Current Database: `other`/p' "$W/now.sql" \
    | grep -vE '^(CREATE DATABASE|USE )' | q modx || return 1
  q modx < "$1" && q modx < "$1" || return 1
  local got; got=$(q modx -e "
    SELECT GROUP_CONCAT(id ORDER BY id) FROM modx_site_content WHERE context_key = 'alpha';
    SELECT content FROM modx_site_content WHERE id = 11;
    SELECT value FROM modx_site_tmplvar_contentvalues WHERE contentid = 11;
    SELECT COUNT(*) FROM modx_site_tmplvar_contentvalues WHERE contentid = 13;
    SELECT value FROM modx_context_setting WHERE context_key = 'alpha' AND \`key\` = 'site_name';
    SELECT GROUP_CONCAT(id ORDER BY id) FROM modx_site_content WHERE context_key = 'beta';
    SELECT content FROM modx_site_content WHERE id = 21;
    SELECT value FROM modx_context_setting WHERE context_key = 'beta' AND \`key\` = 'site_name';
    SELECT GROUP_CONCAT(id ORDER BY id) FROM modx_document_groups;
    SELECT value FROM modx_system_settings WHERE \`key\` = 'site_status';" | tr '\n' '|')
  [ "$got" = "10,11,12|alpha about, as backed up|alpha note, as backed up|0|Alpha, as backed up|20,21,22|beta about, edited after the backup|Beta, renamed|1,2,3|0|" ] \
    || { echo "    state after the plan: $got"; return 1; }
}

# run_case <script> <name> <expect: plan|REFUSED code> <tenant> <at> <now> [scratch client]
run_case() {
  local script=$1 name=$2 expect=$3 tenant=$4 at=$5 now=$6 m=${7:-$W/m-scr} d=${8:-$W/d-scr} out="$W/plan-$name-$RANDOM.sql" o rc
  o=$(TR_MYSQL=$m TR_MYSQLDUMP=$d python3 -I "$script" --tenant "$tenant" --at "$W/$at" --now "$W/$now" --out "$out" 2>&1); rc=$?
  # the scratch copies hold tenant data: none may be left on either server, whatever the outcome
  local left; left=$("$m" --batch --skip-column-names -e "SHOW DATABASES LIKE 'tr\\_%'" 2>&1)
  [ -z "$left" ] || { echo "    $name: scratch left behind: $left"; return 1; }
  if [ "$expect" = plan ]; then
    [ $rc -eq 0 ] && [ -s "$out" ] && proven "$out" && return 0
  else
    [ $rc -eq 1 ] && printf '%s\n' "$o" | grep -q "^$expect:" && [ ! -e "$out" ] && return 0
  fi
  printf '%s' "$o" | grep -q '^Traceback' && echo "    $name: Traceback"
  echo "    $name: rc=$rc out=$( [ -e "$out" ] && echo written || echo none ) :: $(printf '%s' "$o" | tail -c 300)"; return 1
}
plant() {  # plant <guard code or ""> <fault or ""> <out> — a copy of the script with that guard off and that fault in; prints <out>
  python3 - "$SCRIPT" "$1" "$2" "$3" <<'PY'
import sys
src, code, flt, out = sys.argv[1:]
lines = open(src).read().split("\n")
hit = 0
for i, l in enumerate(lines):
    if code and l.rstrip().endswith(f"# guard:{code}"):
        lines[i] = l.replace("refuse(", "(lambda *x: None)(", 1).replace("drop_scratch()", "None", 1); hit += 1
s = "\n".join(lines)
edits = {
  "widen": ("WHERE context_key = '{T}';\",  # fault-point:widen", ";\",  # fault-point:widen"),
  "drop": ("inserts.append(p.stdout)  # fault-point:drop", "inserts.append(\"\" if table == \"site_tmplvar_contentvalues\" else p.stdout)"),
  "outside": ("plan_tail = \"\"  # fault-point:outside", "plan_tail = \"UPDATE `modx_system_settings` SET value = 9;\\n\""),
  "apply": ("plan_tail = \"\"  # fault-point:outside", "plan_tail = \"INSERT INTO `no_such_table` VALUES (1);\\n\""),
}
if flt:
    a, b = edits[flt]; assert a in s, f"fault {flt} did not plant"; s = s.replace(a, b)
assert hit or not code, f"no guard:{code} line"
open(out, "w").write(s); print(out)
PY
}
CASES=(
  "restore|plan|alpha|at.sql|now.sql|"
  "tenant|REFUSED tenant|mgr|at.sql|now.sql|"
  "tenant-quote|REFUSED tenant|al'pha|at.sql|now.sql|"
  "scratch|REFUSED scratch|alpha|at.sql|now.sql|src"
  "no-database|REFUSED no-database|alpha|at-nomodx.sql|now.sql|"
  "schema|REFUSED schema|alpha|at.sql|now-schema.sql|"
  "no-tenant|REFUSED no-tenant|alpha|at.sql|now-notenant.sql|"
  "empty|REFUSED empty|alpha|at-empty.sql|now.sql|"
  "collision|REFUSED collision|alpha|at.sql|now-collision.sql|"
  "orphan|REFUSED orphan|alpha|at.sql|now-orphan.sql|"
  "parent|REFUSED parent|alpha|at-parent.sql|now.sql|"
  "reference|REFUSED reference|alpha|at.sql|now-reference.sql|"
  "dependant|REFUSED dependant|alpha|at.sql|now-dependant.sql|"
  "apply|REFUSED apply|alpha|at.sql|now.sql||apply"
  "outside-changed|REFUSED outside-changed|alpha|at.sql|now.sql||outside"
  "others-changed|REFUSED others-changed|alpha|at.sql|now.sql||widen"
  "tenant-differs|REFUSED tenant-differs|alpha|at.sql|now.sql||drop"
)
one() {  # one <line> — the case with the script as committed (its fault, if it names one, planted in a copy)
  local name expect tenant at now srv flt m d script=$SCRIPT
  IFS='|' read -r name expect tenant at now srv flt <<< "$1"
  m=$W/m-scr; d=$W/d-scr; [ "$srv" = src ] && { m=$W/m-src; d=$W/d-src; }
  [ -n "$flt" ] && { script=$(plant "" "$flt" "$W/fault-$name.py") || return 1; }
  run_case "$script" "$name" "$expect" "$tenant" "$at" "$now" "$m" "$d"
}

fails=0; echo "cases (the script as committed):"
for c in "${CASES[@]}"; do n=${c%%|*}; if one "$c"; then echo "  ok    $n"; else echo "  FAIL  $n"; fails=$((fails+1)); fi; done
[ "${TR_DRILL_CASES_ONLY:-}" = 1 ] && { echo "arms skipped"; [ $fails -eq 0 ]; exit $?; }

reds=0; arms=0; echo "arms (one guard off; its case must fail):"
for c in "${CASES[@]}"; do
  IFS='|' read -r name expect tenant at now srv flt <<< "$c"
  [ "$expect" = plan ] && continue
  code=${expect#REFUSED }; [ "$name" = tenant-quote ] && continue
  copy=$(plant "$code" "$flt" "$W/arm-$name.py") || { echo "  CANNOT ARM $code"; fails=$((fails+1)); continue; }
  arms=$((arms+1)); m=$W/m-scr; d=$W/d-scr; [ "$srv" = src ] && { m=$W/m-src; d=$W/d-src; }
  # red only when the armed copy RAN and came out otherwise: a crash (a traceback) proves nothing about the guard
  if r=$(run_case "$copy" "arm-$name" "$expect" "$tenant" "$at" "$now" "$m" "$d"); then
    echo "  GREEN $code (the case still passed with its guard off)"; fails=$((fails+1))
  elif printf '%s' "$r" | grep -q 'Traceback'; then
    echo "  CRASH $code (the armed copy failed to run): $(printf '%s' "$r" | tail -c 200)"; fails=$((fails+1))
  else echo "  red   $code"; reds=$((reds+1)); fi
done
# the cleanup's arm: the scratch copies left behind must fail the restore case
copy=$(plant cleanup "" "$W/arm-cleanup.py") && arms=$((arms+1)) && {
  if run_case "$copy" arm-cleanup plan alpha at.sql now.sql >/dev/null; then echo "  GREEN cleanup (the case still passed with its guard off)"; fails=$((fails+1))
  else echo "  red   cleanup"; reds=$((reds+1)); fi
  "$W/m-scr" -e "DROP DATABASE IF EXISTS tr_at; DROP DATABASE IF EXISTS tr_now; DROP DATABASE IF EXISTS tr_rehearse"; }
echo "${#CASES[@]} cases, $arms arms, $reds red, $fails failure(s)"
[ $fails -eq 0 ] && [ $reds -eq $arms ]
