#!/bin/bash
# drill-tenant-restore.sh — one MODx tenant restored, the others untouched, on throwaway containers
# (neenv patterns/restore-one-tenant).   ./drill-tenant-restore.sh   needs Docker (docker, or sudo -n docker)
#
# Two MariaDB containers (the image pinned by digest): SRC holds a made-up `modx` database with two tenants (seed.sql on
# MODx 3's table definitions, schema.sql: ten tables — modx_context, modx_site_content,
# modx_site_tmplvar_contentvalues, modx_document_groups, modx_context_setting, modx_context_resource,
# modx_site_templates, modx_site_tmplvars, modx_documentgroup_names, modx_system_settings); its dumps are the backup
# (at) and, after later.sql, the present (now). SCR is the empty scratch server scripts/tenant-restore-modx.py works
# on. Each case runs the script unchanged and must end as named: a plan that, applied twice to a copy of `now`, gives
# alpha back as backed up and keeps beta's later work and the system setting (and stops, changing nothing, when applied
# a second time); a plan whose guards stop it on a live
# database that moved after `now`; or a refusal with its code, no plan file and no scratch copy left behind. Then each
# guard is disabled in a copy of the script, one at a time, and the case named for that guard must FAIL (an armed
# copy that crashes is a failure of the drill, not a red arm). No real database is touched.
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
qs() { dk exec -i $SCR mariadb -uroot --batch --skip-column-names "$@"; }                # the scratch server, as root
dump() { dk exec $SRC mariadb-dump -uroot --all-databases --single-transaction; }        # what the backup job runs

# The backup's moment and the present, plus the variants each case needs (each a fresh source state, dumped).
base() { q -e 'DROP DATABASE IF EXISTS modx; DROP DATABASE IF EXISTS other; CREATE DATABASE modx; CREATE DATABASE other;
               CREATE TABLE other.t (id int primary key); INSERT INTO other.t VALUES (1);' \
         && q modx < "$HERE/schema.sql" && q modx < "$HERE/seed.sql"; }
mk() {  # mk <file> <extra sql before the dump> [later]
  base || { echo "cannot run: the seed did not load"; exit 2; }
  [ "${3:-}" = later ] && { q modx < "$HERE/later.sql" || { echo "cannot run: later.sql did not load"; exit 2; }; }
  [ -n "$2" ] && { q modx -e "$2" || { echo "cannot run: variant $1 did not load"; exit 2; }; }
  dump > "$W/$1" || { echo "cannot run: dump $1"; exit 2; }
  grep -q 'Dump completed on' "$W/$1" || { echo "cannot run: dump $1 incomplete"; exit 2; }
}
mk at.sql ""
mk at-empty.sql "DELETE FROM modx_site_content WHERE context_key = 'alpha'"
mk at-parent.sql "UPDATE modx_site_content SET parent = 20 WHERE id = 12"
dk exec $SRC mariadb-dump -uroot --databases other > "$W/at-nomodx.sql" || { echo "cannot run: dump nomodx"; exit 2; }
mk at-extras.sql "CREATE TABLE modx_gallery_item (id int primary key, resource int NOT NULL)"
sleep 1.1   # every `now` is dumped at least a second after every `at` (dump dates have one-second steps)
mk now.sql "" later
mk now-notenant.sql "DELETE FROM modx_context WHERE \`key\` = 'alpha'" later
mk now-collision.sql "INSERT INTO modx_site_content (id, pagetitle, description, alias, content, template, context_key) VALUES (12, 'Beta took 12', '', 'b12', 'b', 2, 'beta')" later
mk now-orphan.sql "INSERT INTO modx_site_tmplvar_contentvalues (id, tmplvarid, contentid, value) VALUES (9, 1, 12, 'orphan')" later
mk now-reference.sql "DELETE FROM modx_site_templates WHERE id = 2" later
mk now-dependant.sql "INSERT INTO modx_site_content (id, pagetitle, description, alias, parent, content, template, context_key) VALUES (23, 'Beta under alpha junk', '', 'b23', 13, 'b', 2, 'beta')" later
mk now-dependant-setting.sql "INSERT INTO modx_context_setting (context_key, \`key\`, value) VALUES ('beta', 'error_page', '13')" later
mk now-dependant-link.sql "UPDATE modx_site_content SET content = 'see [[~13]] for junk' WHERE id = 21" later
mk now-schema.sql "ALTER TABLE modx_site_content ADD COLUMN extra int NOT NULL DEFAULT 0" later
mk now-engine.sql "ALTER TABLE modx_context_setting ENGINE = MyISAM" later
mk now-extras.sql "CREATE TABLE modx_gallery_item (id int primary key, resource int NOT NULL)" later
head -n -8 "$W/at.sql" > "$W/at-cut.sql"                                                       # a dump cut short
sed -E 's/^-- Dump completed on .*/-- Dump completed on 2020-01-01 00:00:00/' "$W/now.sql" > "$W/now-old.sql"   # a stale `now`
sed -E 's/^-- Dump completed on .*/-- Dump completed on 2019-01-01 00:00:00/' "$W/at.sql" > "$W/at-old.sql"     # ... after an older `at`

# client wrappers: docker exec into a container (through sudo -n when needed); scr and src as root, lim as a user who
# may see only tr_* (the scratch guard must not trust what such a user cannot see)
for spec in "scr $SCR -uroot" "src $SRC -uroot" "lim $SCR -ulim"; do set -- $spec
  printf '#!/bin/bash\nif docker info >/dev/null 2>&1; then D=docker; else D="sudo -n docker"; fi\nexec $D exec -i %s mariadb %s "$@"\n' $2 $3 > "$W/m-$1"
  printf '#!/bin/bash\nif docker info >/dev/null 2>&1; then D=docker; else D="sudo -n docker"; fi\nexec $D exec -i %s mariadb-dump %s "$@"\n' $2 $3 > "$W/d-$1"
done
chmod +x "$W"/m-* "$W"/d-*
qs -e "CREATE USER lim@'%'; CREATE USER lim@localhost; GRANT ALL ON \`tr\\_%\`.* TO lim@'%'; GRANT ALL ON \`tr\\_%\`.* TO lim@localhost;" \
  || { echo "cannot run: the limited user"; exit 2; }

# the `modx` section of a dump, for loading it as the live database (not the `mysql` one that follows it)
# (with the dump's header: its charset and session settings, as a real restore of it would load)
modx_of() { awk 'BEGIN { inside = 1 } /^-- Current Database: /{ inside = ($0 ~ /`modx`/); next } inside && !/^(CREATE DATABASE|USE )/' "$1"; }
live_from() {  # live_from <dump> — the source server's `modx` becomes that dump's
  q -e 'DROP DATABASE IF EXISTS modx; CREATE DATABASE modx' && modx_of "$W/$1" | q modx; }

# The plan, applied to a fresh copy of `now` on the source server, gives alpha back as backed up and keeps everything
# that is not alpha's — measured here by the drill, not by the script. Applied a second time it must stop on its guards
# (the database no longer matches `now`) and change nothing.
state() { q modx -e "
    SELECT GROUP_CONCAT(id ORDER BY id) FROM modx_site_content WHERE context_key = 'alpha';
    SELECT content FROM modx_site_content WHERE id = 11;
    SELECT value FROM modx_site_tmplvar_contentvalues WHERE contentid = 11;
    SELECT COUNT(*) FROM modx_site_tmplvar_contentvalues WHERE contentid = 13;
    SELECT value FROM modx_context_setting WHERE context_key = 'alpha' AND \`key\` = 'site_name';
    SELECT GROUP_CONCAT(id ORDER BY id) FROM modx_site_content WHERE context_key = 'beta';
    SELECT content FROM modx_site_content WHERE id = 21;
    SELECT value FROM modx_context_setting WHERE context_key = 'beta' AND \`key\` = 'site_name';
    SELECT GROUP_CONCAT(id ORDER BY id) FROM modx_document_groups;
    SELECT value FROM modx_system_settings WHERE \`key\` = 'site_status';" | tr '\n' '|'; }
RESTORED="10,11,12|alpha about, as backed up|alpha note, as backed up|0|Alpha, as backed up|20,21,22|beta about, edited after the backup|Beta, renamed|1,2,3|0|"
proven() {  # proven <plan>
  live_from now.sql || return 1
  q modx < "$1" || return 1
  local got o; got=$(state)
  [ "$got" = "$RESTORED" ] || { echo "    state after the plan: $got"; return 1; }
  o=$(q modx < "$1" 2>&1) && { echo "    a second apply was not stopped"; return 1; }
  printf '%s' "$o" | grep -q 'differs from --now' || { echo "    the second apply failed, not on its guard"; return 1; }
  [ "$(state)" = "$RESTORED" ] || { echo "    the stopped second apply changed the database"; return 1; }
}
# The live database moved after `now` (alpha's page edited again): the plan's guards must stop it and write nothing.
stopped() {  # stopped <plan>
  live_from now.sql && q modx -e "UPDATE modx_site_content SET content = 'alpha about, edited after now' WHERE id = 11" || return 1
  local before after o; before=$(state)
  o=$(q modx < "$1" 2>&1) && { echo "    the plan applied to a moved live database"; return 1; }
  printf '%s' "$o" | grep -q 'differs from --now' || { echo "    the plan failed, not on its guard: $o"; return 1; }
  after=$(state); [ "$before" = "$after" ] || { echo "    the stopped plan changed the live database"; return 1; }
}

# run_case <script> <name> <expect> <tenant> <at> <now> <client> <env>
#   expect: plan | stopped | REFUSED <code>
run_case() {
  local script=$1 name=$2 expect=$3 tenant=$4 at=$5 now=$6 cl=${7:-scr} envs=${8:-} out="$W/plan-$2-$RANDOM.sql" o rc left
  [ "$cl" = lim ] && qs -e 'CREATE DATABASE hidden'        # a database the limited user cannot see
  o=$(env TR_MYSQL="$W/m-$cl" TR_MYSQLDUMP="$W/d-$cl" $envs python3 -I "$script" --tenant "$tenant" --at "$W/$at" --now "$W/$now" --out "$out" 2>&1); rc=$?
  [ "$cl" = lim ] && qs -e 'DROP DATABASE hidden'
  printf '%s' "$o" | grep -q '^Traceback' && echo "    $name: Traceback"
  if [[ $name == *apply ]]; then
    # the failed plan must have left the rehearsal copy as it was: the script says so, and the drill measures it
    # (TR_KEEP_SCRATCH=1 kept the copies; they are measured, then dropped, before anything is judged)
    local a b; a=$(qs -e 'CHECKSUM TABLE tr_now.modx_site_content, tr_now.modx_context_setting, tr_now.modx_site_tmplvar_contentvalues' 2>&1 | cut -f2)
    b=$(qs -e 'CHECKSUM TABLE tr_rehearse.modx_site_content, tr_rehearse.modx_context_setting, tr_rehearse.modx_site_tmplvar_contentvalues' 2>&1 | cut -f2)
    qs -e 'DROP DATABASE IF EXISTS tr_at; DROP DATABASE IF EXISTS tr_now; DROP DATABASE IF EXISTS tr_rehearse'
    printf '%s' "$o" | grep -q 'rolled back: yes' || { echo "    $name: the script did not report a rollback :: $(printf '%s' "$o" | tail -c 200)"; return 1; }
    [ -n "$a" ] && [ "$a" = "$b" ] || { echo "    $name: tr_rehearse differs from tr_now after the failed plan"; return 1; }
  fi
  # the scratch copies hold tenant data: none may be left on the scratch server, whatever the outcome
  left=$(qs -e "SHOW DATABASES LIKE 'tr\\_%'" 2>&1)
  [ -z "$left" ] || { echo "    $name: scratch left behind: $left"; qs -e 'DROP DATABASE IF EXISTS tr_at; DROP DATABASE IF EXISTS tr_now; DROP DATABASE IF EXISTS tr_rehearse'; return 1; }
  case "$expect" in
    plan)    [ $rc -eq 0 ] && [ -s "$out" ] && proven "$out" && return 0 ;;
    stopped) [ $rc -eq 0 ] && [ -s "$out" ] && stopped "$out" && return 0 ;;
    *)       [ $rc -eq 1 ] && printf '%s\n' "$o" | grep -q "^$expect:" && [ ! -e "$out" ] && return 0 ;;
  esac
  echo "    $name: rc=$rc out=$( [ -e "$out" ] && echo written || echo none ) :: $(printf '%s' "$o" | tail -c 300)"; return 1
}

# plant <guard marker or ""> <fault or ""> <out> — a copy of the script with that guard off and that fault in
plant() {
  python3 - "$SCRIPT" "$1" "$2" "$3" <<'PY'
import sys
src, code, flt, out = sys.argv[1:]
lines = open(src).read().split("\n")
hit = 0
for i, l in enumerate(lines):
    if code and l.rstrip().endswith(f"# guard:{code}"):
        if "refuse(" in l:
            lines[i] = l.replace("refuse(", "(lambda *x: None)(", 1)
        elif "drop_scratch()" in l:
            lines[i] = l.replace("drop_scratch()", "None", 1)
        elif l.lstrip().startswith("guards = "):
            lines[i] = l[:len(l) - len(l.lstrip())] + 'guards = ""'
        else:
            raise SystemExit(f"guard:{code} line has nothing to turn off")
        hit += 1
s = "\n".join(lines)
edits = {
  "widen": ("WHERE context_key = '{T}';\",  # fault-point:widen", ";\",  # fault-point:widen"),
  "drop": ("inserts.append(\"\\n\".join(kept) + (\"\\n\" if kept else \"\"))  # fault-point:drop",
           "inserts.append(\"\" if table == \"site_tmplvar_contentvalues\" else \"\\n\".join(kept) + (\"\\n\" if kept else \"\"))"),
  "outside": ("plan_tail = \"\"  # fault-point:outside", "plan_tail = \"UPDATE `modx_system_settings` SET value = 9;\\n\""),
  # a statement that fails halfway: after the deletes, before the inserts
  "mid": ("mid = \"\"  # fault-point:mid", "mid = \"INSERT INTO `no_such_table` VALUES (1);\\n\""),
}
if flt:
    a, b = edits[flt]; assert a in s, f"fault {flt} did not plant"; s = s.replace(a, b)
assert hit or not code, f"no guard:{code} line"
open(out, "w").write(s); print(out)
PY
}

# name | expect | tenant | at | now | client | fault | arm marker (default: the code) | env
CASES=(
  "restore|plan|alpha|at.sql|now.sql||||"
  "live|stopped|alpha|at.sql|now.sql|||live|"
  "tenant|REFUSED tenant|mgr|at.sql|now.sql||||"
  "tenant-case|REFUSED tenant|MGR|at.sql|now.sql|||-|"
  "tenant-web|REFUSED tenant|web|at.sql|now.sql|||-|"
  "tenant-quote|REFUSED tenant|al'pha|at.sql|now.sql|||-|"
  "incomplete|REFUSED incomplete|alpha|at-cut.sql|now.sql||||"
  "order|REFUSED order|alpha|now.sql|at.sql||||"
  "stale-now|REFUSED stale-now|alpha|at-old.sql|now-old.sql||||"
  "scratch|REFUSED scratch|alpha|at.sql|now.sql|src|||"
  "scratch-priv|REFUSED scratch|alpha|at.sql|now.sql|lim||scratch-priv|"
  "no-database|REFUSED no-database|alpha|at-nomodx.sql|now.sql||||"
  "schema|REFUSED schema|alpha|at.sql|now-schema.sql||||"
  "engine|REFUSED engine|alpha|at.sql|now-engine.sql||||"
  "extras|REFUSED extras|alpha|at-extras.sql|now-extras.sql||||"
  "no-tenant|REFUSED no-tenant|alpha|at.sql|now-notenant.sql||||"
  "empty|REFUSED empty|alpha|at-empty.sql|now.sql||||"
  "collision|REFUSED collision|alpha|at.sql|now-collision.sql||||"
  "orphan|REFUSED orphan|alpha|at.sql|now-orphan.sql||||"
  "parent|REFUSED parent|alpha|at-parent.sql|now.sql||||"
  "dependant|REFUSED dependant|alpha|at.sql|now-dependant.sql||||"
  "dependant-setting|REFUSED dependant|alpha|at.sql|now-dependant-setting.sql|||dependant|"
  "dependant-link|REFUSED dependant|alpha|at.sql|now-dependant-link.sql|||dependant|"
  "reference|REFUSED reference|alpha|at.sql|now-reference.sql||||"
  "digest|REFUSED digest|alpha|at.sql|now.sql||||TR_GROUP_CONCAT_MAX=64"
  "apply|REFUSED apply|alpha|at.sql|now.sql||mid||TR_KEEP_SCRATCH=1"
  "outside-changed|REFUSED outside-changed|alpha|at.sql|now.sql||outside||"
  "others-changed|REFUSED others-changed|alpha|at.sql|now.sql||widen||"
  "tenant-differs|REFUSED tenant-differs|alpha|at.sql|now.sql||drop||"
)
one() {  # one <line> — the case with the script as committed (its fault, if it names one, planted in a copy)
  local name expect tenant at now cl flt armk envs script=$SCRIPT
  IFS='|' read -r name expect tenant at now cl flt armk envs <<< "$1"
  [ -n "$flt" ] && { script=$(plant "" "$flt" "$W/fault-$name.py") || return 1; }
  run_case "$script" "$name" "$expect" "$tenant" "$at" "$now" "${cl:-scr}" "$envs"
}

fails=0; echo "cases (the script as committed):"
for c in "${CASES[@]}"; do n=${c%%|*}; if one "$c"; then echo "  ok    $n"; else echo "  FAIL  $n"; fails=$((fails+1)); fi; done
[ "${TR_DRILL_CASES_ONLY:-}" = 1 ] && { echo "${#CASES[@]} cases, arms skipped, $fails failure(s)"; [ $fails -eq 0 ]; exit $?; }

reds=0; arms=0; echo "arms (one guard off; its case must fail):"
for c in "${CASES[@]}"; do
  IFS='|' read -r name expect tenant at now cl flt armk envs <<< "$c"
  [ "$expect" = plan ] && continue
  [ "$armk" = - ] && continue                                   # a second case of a guard already armed
  code=${armk:-${expect#REFUSED }}
  copy=$(plant "$code" "$flt" "$W/arm-$name.py") || { echo "  CANNOT ARM $code"; fails=$((fails+1)); continue; }
  arms=$((arms+1))
  # red only when the armed copy RAN and came out otherwise: a crash (a traceback) proves nothing about the guard
  if r=$(run_case "$copy" "arm-$name" "$expect" "$tenant" "$at" "$now" "${cl:-scr}" "$envs"); then
    echo "  GREEN $name (the case still passed with guard:$code off)"; fails=$((fails+1))
  elif printf '%s' "$r" | grep -q 'Traceback'; then
    echo "  CRASH $name (the armed copy failed to run): $(printf '%s' "$r" | tail -c 200)"; fails=$((fails+1))
  else echo "  red   $name (guard:$code)"; reds=$((reds+1)); fi
done
# the cleanup's arm: the scratch copies left behind must fail the restore case
copy=$(plant cleanup "" "$W/arm-cleanup.py") && arms=$((arms+1)) && {
  if run_case "$copy" arm-cleanup plan alpha at.sql now.sql >/dev/null; then echo "  GREEN cleanup (the case still passed with its guard off)"; fails=$((fails+1))
  else echo "  red   cleanup"; reds=$((reds+1)); fi; }
echo "${#CASES[@]} cases, $arms arms, $reds red, $fails failure(s)"
[ $fails -eq 0 ] && [ $reds -eq $arms ]
