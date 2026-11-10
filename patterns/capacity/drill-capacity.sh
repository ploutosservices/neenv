#!/usr/bin/env bash
# drill-capacity.sh: the capacity rules fire on a filling disk and a failing drive, and stay quiet beside them.
#
#   ./drill-capacity.sh        # promtool: the rules' own tests pass, and copies with one guard removed each fail them
#   Exit codes, the same in every neenv drill: 0 every case came out as it must; 1 one did not (or the rules are
#   refused); 2 it could not run (a missing tool or file).
#
# Needs promtool, and capacity.yml and capacity.test.yml beside this script.
set -u
set -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
fails=0
ok()   { printf 'ok    %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
command -v promtool >/dev/null || { echo "promtool is required" >&2; exit 2; }
[[ -f $HERE/capacity.yml && -f $HERE/capacity.test.yml ]] || { echo "capacity.yml and capacity.test.yml must be beside this script" >&2; exit 2; }
d=$(mktemp -d "${TMPDIR:-/tmp}/drill-capacity.XXXXXX") || exit 2
trap 'rm -rf "$d"' EXIT
promtool check rules "$HERE/capacity.yml" >/dev/null || { echo "promtool refuses capacity.yml: the rules are wrong" >&2; exit 1; }
run_case() {   # $1 name, $2 sed expression ('' for none), $3 pass|fail, $4 the alert whose test must be the one failing
  mkdir -p "$d/$1"
  if [[ -n $2 ]]; then sed -E "$2" "$HERE/capacity.yml" >"$d/$1/capacity.yml"; else cp "$HERE/capacity.yml" "$d/$1/"; fi
  [[ -n $2 ]] && cmp -s "$HERE/capacity.yml" "$d/$1/capacity.yml" && { echo "case $1 changed nothing in the rules" >&2; exit 2; }
  # a broken copy must still be valid rules: a copy that no longer parses would "fail as it must" and prove nothing
  promtool check rules "$d/$1/capacity.yml" >/dev/null 2>&1 || { echo "case $1 does not parse: the case is wrong" >&2; exit 2; }
  cp "$HERE/capacity.test.yml" "$d/$1/"
  local got; if promtool test rules "$d/$1/capacity.test.yml" >"$d/$1/out" 2>&1; then got=pass; else got=fail; fi
  if [[ $got != "$3" ]]; then fail "$1: the tests $got, not $3"; return; fi
  if [[ -n ${4:-} ]] && ! grep -q "alertname: $4," "$d/$1/out"; then fail "$1: the tests failed, but not on $4"; return; fi
  ok "$1: the tests $got, as they must${4:+ (on $4)}"
}
run_case as-published '' pass
# no 70% guard: a disk at 20% that is filling pages a week early
run_case no-level-guard 's/\) < 0\.3$/) < 1/' fail DiskWillFillIn7Days
# a one-day horizon: a disk with five days left is not reported
run_case one-day-horizon 's/\[3d\], 7 \* 86400\)/[3d], 86400)/' fail DiskWillFillIn7Days
# no SMART-available guard: a virtual disk with no SMART pages for ever
run_case no-available-guard 's/ and on \(instance, disk, type\) smartmon_device_smart_available == 1//' fail DriveSmartUnhealthy
# no age threshold on the drive facts: a file written five minutes ago is called stale
run_case no-facts-age 's/> 3 \* 3600/> 0/' fail DriveFactsStale
# no `unless`: every machine is reported as having no drive facts
run_case no-missing-guard 's/ unless on \(instance\) node_textfile_mtime_seconds\{file=~"\.\*\/smartmon\\\\\.prom"\}//' fail DriveFactsMissing
(( fails == 0 )) || { echo "$fails case(s) did not come out as they must"; exit 1; }
echo "all checks passed"
