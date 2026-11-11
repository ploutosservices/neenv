#!/bin/bash
# drill-retention.sh — a departed tenant's data leaves the backups on the backup schedule, and nothing keeps it longer.
#
# A scratch restic repository gets one snapshot a month (restic backup --time). Only the monthly rule is drilled:
# with one snapshot a month, keep-daily and keep-weekly keep nothing monthly does not already keep.
#   1 dates     export by notice + 30 days; live data deleted by export + 30 days
#   2 window    with KEEP months kept, KEEP-1 months after the deletion month a non-final snapshot still holds the tenant
#   3 agedout   KEEP months after the deletion month no snapshot holds it
#   4 owngroup  a snapshot group holding only the tenant (its own host/path) gets no new snapshots, so forget keeps its
#               last KEEP for ever; the departure step forgets that group by name, and then it holds nothing
#   5 final     a snapshot tagged `final` (kept for ever) that holds the tenant is refused by the departure check;
#               after `restic rewrite --forget --exclude` and prune, the check passes and the rewrite keeps the tag
# POLICY=first (default: daily 7, weekly 5, monthly 12, keep-tag final) or POLICY=offsite (daily 7, weekly 8, monthly 24).
# ARM=nokeep     no forget runs:                      only 3 must fail
# ARM=finaltag   a final copy is planted, no check:   only 3 must fail
# ARM=nogroup    the departure step is skipped:       only 4 must fail
# Exit: 0 proved (with ARM: exactly that arm's case failed), 1 not proved, 2 could not run.
set -uo pipefail
for c in restic python3; do command -v $c >/dev/null || { echo "cannot run: no $c"; exit 2; }; done
case "${ARM:-}" in ""|finaltag|nokeep|nogroup) ;; *) echo "cannot run: unknown ARM=$ARM (nokeep, finaltag, nogroup)"; exit 2 ;; esac
case "${POLICY:-first}" in
  first)   K=12; KEEP=(--keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-tag final) ;;
  offsite) K=24; KEEP=(--keep-daily 7 --keep-weekly 8 --keep-monthly 24) ;;
  *) echo "cannot run: POLICY is first or offsite"; exit 2 ;;
esac
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export RESTIC_REPOSITORY=$W/repo RESTIC_PASSWORD=drill-only RESTIC_CACHE_DIR=$W/cache
restic init -q >/dev/null 2>&1 || { echo "cannot run: restic init"; exit 2; }
: > "$W/failed"; pass=0
ok()  { echo "  ok    $1  $2"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1  $2"; echo "$1" >> "$W/failed"; }
die2() { echo "cannot run: $*"; exit 2; }

# 1 dates
notice=2027-03-01; export_by=$(date -d "$notice + 30 days" +%F); delete_by=$(date -d "$export_by + 30 days" +%F)
[[ $export_by == 2027-03-31 && $delete_by == 2027-04-30 ]] && ok dates "notice $notice, export by $export_by, delete by $delete_by" \
  || bad dates "export $export_by, delete $delete_by"

DEL=10                                   # the last month whose snapshot holds the tenant
mkdir -p "$W/app" "$W/own"
when() { date -d "2024-01-15 + $1 months" '+%Y-%m-%d 12:00:00'; }
snap_month() {  # the application's tree (shared with other tenants) and, while it exists, the tenant's own tree
  echo "month $1" > "$W/app/common.txt"
  if (( $1 <= DEL )); then echo rows > "$W/app/tenant-acme.sql"; else rm -f "$W/app/tenant-acme.sql"; fi
  ( cd "$W/app" && restic backup -q --host app --time "$(when $1)" --tag app . >/dev/null 2>&1 ) || die2 "backup app $1"
  if (( $1 <= DEL )); then
    echo files > "$W/own/acme-files.tar"
    ( cd "$W/own" && restic backup -q --host acme-files --time "$(when $1)" --tag app . >/dev/null 2>&1 ) || die2 "backup own $1"
  fi
}
ids() {  # ids [restic snapshots filters] — short ids, fail closed
  local j; j=$(restic snapshots --json "$@" 2>/dev/null) || die2 "restic snapshots"
  python3 -c 'import json,sys;[print(s["short_id"]) for s in (json.load(sys.stdin) or [])]' <<<"$j" || die2 "parse snapshots"
}
holds() {  # holds <id> <file> — 0 if the snapshot holds the file; fail closed
  local l; l=$(restic ls "$1" 2>/dev/null) || die2 "restic ls $1"
  grep -q "/$2\$" <<<"$l"
}
count() {  # count <file> [filters] — snapshots holding the file
  local n=0 id; for id in $(ids "${@:2}"); do holds "$id" "$1" && n=$((n+1)); done; echo $n
}
nonfinal() {  # count <file> over snapshots not tagged final
  local n=0 id fin; fin=" $(ids --tag final | tr '\n' ' ') "
  for id in $(ids); do [[ "$fin" == *" $id "* ]] && continue; holds "$id" "$1" && n=$((n+1)); done; echo $n
}
DONE=0
upto() {  # snapshots up to month <m>, then the nightly prune (unless ARM=nokeep)
  local i; for (( i=DONE; i<=$1; i++ )); do snap_month $i; done; DONE=$(( $1 + 1 ))
  [[ "${ARM:-}" == nokeep ]] || restic forget -q --prune "${KEEP[@]}" >/dev/null 2>&1 || die2 "forget"
}
if [[ "${ARM:-}" == finaltag ]]; then
  echo rows > "$W/app/tenant-acme.sql"
  ( cd "$W/app" && restic backup -q --host app --time "$(when 0)" --tag final . >/dev/null 2>&1 ) || die2 "backup final"
fi

# 2 window, 3 agedout — the shared application tree
upto $(( DEL + K - 1 ))
n=$(nonfinal tenant-acme.sql)
(( n > 0 )) && ok window "$(( K - 1 )) months after the deletion month, $n non-final snapshot(s) still hold the tenant" \
  || bad window "the tenant was gone $(( K - 1 )) months after the deletion month"
upto $(( DEL + K ))
n=$(count tenant-acme.sql)
(( n == 0 )) && ok agedout "$K months after the deletion month, no snapshot holds the tenant" \
  || bad agedout "$n snapshot(s) still hold the tenant $K months after the deletion month"

# 4 owngroup — the tenant's own tree stopped being backed up, so its group never ages out by itself
n=$(count acme-files.tar --host acme-files)
if (( n > 0 )); then
  if [[ "${ARM:-}" != nogroup ]]; then
    restic forget -q --prune --host acme-files $(ids --host acme-files) >/dev/null 2>&1 || die2 "group forget"
  fi
  m=$(count acme-files.tar --host acme-files)
  (( m == 0 )) && ok owngroup "its own group kept $n snapshot(s) after the window; the departure step forgot them" \
    || bad owngroup "its own group still holds $m snapshot(s): nothing ages out a group with no new snapshots"
else
  bad owngroup "the own group was already empty ($n): the drill did not plant what it tests"
fi

# 5 final — refused, rewritten, then passes
check_departure() {  # prints final snapshots holding the tenant; rc 1 if any
  local id r=0; for id in $(ids --tag final); do holds "$id" tenant-acme.sql && { echo "$id"; r=1; }; done; return $r
}
if [[ "${ARM:-}" != finaltag && $K == 12 ]]; then
  echo rows > "$W/app/tenant-acme.sql"
  ( cd "$W/app" && restic backup -q --host app --time "$(when 0)" --tag final . >/dev/null 2>&1 ) || die2 "backup final"
  if out=$(check_departure); then bad final "a final snapshot holding the tenant was not refused"
  else
    fid=$out; path=$(restic ls "$fid" 2>/dev/null | grep '/tenant-acme.sql$' | head -1)
    restic rewrite -q --forget --exclude "$path" "$fid" >/dev/null 2>&1 && restic prune -q >/dev/null 2>&1 || die2 "rewrite"
    newfin=$(ids --tag final | wc -l)
    if check_departure >/dev/null && (( newfin == 1 )); then
      ok final "final snapshot $fid refused; after rewrite --forget --exclude and prune the check passes and one final copy remains"
    else bad final "after the rewrite the check still refuses, or the final copy is gone (final snapshots: $newfin)"; fi
  fi
elif [[ $K == 24 ]]; then echo "  --    final  not run: the off-site policy keeps no tag for ever"; fi

echo
failed=$(sort -u "$W/failed" | tr '\n' ' ')
if [[ -n "${ARM:-}" ]]; then
  want="agedout "; [[ $ARM == nogroup ]] && want="owngroup "
  [[ "$failed" == "$want" ]] && { echo "retention drill ARM=$ARM: red as designed (only ${want% } failed)"; exit 0; }
  echo "retention drill ARM=$ARM: NOT PROVED (failed: ${failed:-none}; wanted ${want% })"; exit 1
fi
[[ -z "$failed" ]] && { echo "retention drill (POLICY=${POLICY:-first}): $pass passed, 0 failed"; exit 0; }
echo "retention drill: $pass passed, failed: $failed"; exit 1
