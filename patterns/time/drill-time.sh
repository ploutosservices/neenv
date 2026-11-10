#!/usr/bin/env bash
# drill-time.sh: this machine keeps time from several agreeing sources, one of them authenticated, and is close to them.
#
#   ./drill-time.sh machine          # chrony on this machine: sources, agreement, NTS, synchronised, offset
#   ./drill-time.sh rules            # promtool: the rules' own tests pass, and copies with a guard removed fail them
#   Exit codes, the same in every neenv drill: 0 the run proved what it set out to (rules: every case came out as it
#   must); 1 it did not; 2 it could not run (a missing tool).
#
# machine needs chronyc and root (or chrony's group), because chrony shows its NTS state only to them; it changes nothing. rules needs promtool and time.yml and time.test.yml beside this
# script.
set -u
set -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
fails=0
failed=()
ok()   { printf 'ok    %s\n' "${*:2}"; }
fail() { printf 'FAIL  %s\n' "${*:2}"; fails=$((fails + 1)); failed+=("$1"); }

drill_machine() {
  command -v chronyc >/dev/null || { echo "chronyc is required: this mode reads chrony" >&2; exit 2; }
  local src auth track
  src=$(chronyc -n -c sources 2>&1) || { echo "chronyc cannot reach chronyd: $src" >&2; exit 2; }
  # authdata is privileged; a check that cannot see the NTS state must not pass, so it cannot run at all
  auth=$(chronyc -c -N authdata 2>&1) || {
    grep -q 'Not authorised' <<<"$auth" && echo "reading the NTS state needs root (or chrony's socket group): run with sudo" >&2 \
      || echo "chronyc authdata failed: $auth" >&2
    exit 2; }
  track=$(chronyc -c tracking 2>/dev/null) || { echo "chronyc tracking failed" >&2; exit 2; }
  local n usable
  n=$(grep -c '^\^' <<<"$src")
  usable=$(awk -F, '$1=="^" && ($2=="*" || $2=="+" || $2=="-")' <<<"$src" | wc -l)
  (( n >= 3 )) && ok sources "$n sources listed" || fail sources "only $n source(s) listed; one bad source would steer the clock"
  (( usable >= 2 )) && ok agree "$usable sources usable and agreeing" || fail agree "only $usable usable source(s)"
  # a live NTS key: mode NTS with cookies in hand (field 9); a key whose cookies ran out is not one
  local nts; nts=$(awk -F, '$2=="NTS" && $9+0 > 0 {print $1}' <<<"$auth" | paste -sd' ' -)
  [[ -n $nts ]] && ok nts "authenticated (NTS) sources with cookies: $nts" || fail nts "no NTS source holds a key and cookies"
  grep -q '^\^,\*' <<<"$src" && ok synced "a source is selected" || fail synced "no source is selected: the clock is free-running"
  # tracking, -c: field 5 is the system time offset in seconds
  local off; off=$(awk -F, '{print $5}' <<<"$track")
  awk -v o="$off" 'BEGIN { exit !(o < 0.05 && o > -0.05) }' && ok offset "offset ${off}s, within 50 ms" || fail offset "offset ${off}s, beyond 50 ms"
}

drill_rules() {
  command -v promtool >/dev/null || { echo "promtool is required" >&2; exit 2; }
  [[ -f $HERE/time.yml && -f $HERE/time.test.yml ]] || { echo "time.yml and time.test.yml must be beside this script" >&2; exit 2; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/drill-time.XXXXXX") || exit 2
  trap 'rm -rf "$d"' EXIT
  promtool check rules "$HERE/time.yml" >/dev/null || { echo "promtool refuses time.yml: the rules are wrong" >&2; exit 1; }
  run_case() {
    mkdir -p "$d/$1"
    if [[ -n $2 ]]; then sed -E "$2" "$HERE/time.yml" >"$d/$1/time.yml"; else cp "$HERE/time.yml" "$d/$1/"; fi
    [[ -n $2 ]] && cmp -s "$HERE/time.yml" "$d/$1/time.yml" && { echo "case $1 changed nothing in the rules"; exit 2; }
    cp "$HERE/time.test.yml" "$d/$1/"
    local got; if promtool test rules "$d/$1/time.test.yml" >"$d/$1/out" 2>&1; then got=pass; else got=fail; fi
    if [[ $got == "$3" ]]; then ok "$1" "$1: the tests $got, as they must"; else fail "$1" "$1: the tests $got, not $3"; fi
  }
  run_case as-published '' pass
  # no threshold: a clock 1 ms off is reported
  run_case no-threshold 's/> 0\.05/> 0/' fail
  # no `abs`: a clock that is BEHIND is never reported
  run_case no-abs 's/abs\((chrony_tracking_system_offset_seconds)\)/\1/' fail
  # no age threshold: a chrony that reports every minute is called stale
  run_case no-stale-age 's/> 600/> 0/' fail
}

case ${1:-} in
  machine) drill_machine ;;
  rules)   drill_rules ;;
  *)       sed -n '2,10p' "$0"; exit 2 ;;
esac
(( fails == 0 )) || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
