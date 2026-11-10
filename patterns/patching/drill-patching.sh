#!/usr/bin/env bash
# drill-patching.sh: the patch facts reach the exporter, and the judges fire on a stuck update and stay quiet on a normal one.
#
#   ./drill-patching.sh                    # local: a throwaway node_exporter reading both directories; every check must pass
#   ARM=onedir ./drill-patching.sh         # the same exporter reading only its own directory: exactly the 3 patch-fact checks must FAIL
#   ./drill-patching.sh rules              # promtool: the rules' own tests pass, and two rules with their guard removed fail them
#   ./drill-patching.sh machine            # this machine: nightly security updates on, no automatic reboot, the facts fresh
#   Exit codes, the same in every neenv drill: 0 the run proved what it set out to (no ARM: every check passed;
#   an ARM: exactly that arm's checks failed); 1 it did not; 2 it could not run (a missing tool, a setup step).
#
# local needs bash, curl and node_exporter (Debian: prometheus-node-exporter; NODE_EXPORTER_BIN=/path picks another).
# rules needs promtool and patching.yml and patching.test.yml beside this script. machine needs a Debian-family host.
set -u
set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ARM=${ARM:-}
fails=0
failed=()   # the id of every failed check, so an arm run can be judged by WHICH checks failed, not how many
ok()   { printf 'ok    %s\n' "${*:2}"; }
fail() { printf 'FAIL  %s\n' "${*:2}"; fails=$((fails + 1)); failed+=("$1"); }

drill_local() {
  local bin=${NODE_EXPORTER_BIN:-}
  if [[ -z $bin ]]; then
    bin=$(command -v prometheus-node-exporter || command -v node_exporter || true)
  fi
  [[ -n $bin && -x $bin ]] || { echo "node_exporter is required (or NODE_EXPORTER_BIN=/path)" >&2; exit 2; }
  command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }
  [[ -z $ARM || $ARM == onedir ]] || { echo "ARM must be empty or onedir" >&2; exit 2; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/drill-patching.XXXXXX")
  trap '[[ -n ${pid:-} ]] && kill "$pid" 2>/dev/null; rm -rf "$d"' EXIT
  mkdir -p "$d/own" "$d/collectors"
  # the machine's own facts, in the directory the exporter was always told to read
  printf 'estate_check_ok{check="example"} 1\n' >"$d/own/checks.prom"
  # what Debian's collectors write, in the directory they write to
  cat >"$d/collectors/apt.prom" <<'EOF'
# HELP apt_upgrades_pending Apt packages pending updates by origin.
# TYPE apt_upgrades_pending gauge
apt_upgrades_pending{arch="amd64",origin="Debian:trixie-security/stable-security"} 2
# HELP apt_package_cache_timestamp_seconds Apt update last run time.
# TYPE apt_package_cache_timestamp_seconds gauge
apt_package_cache_timestamp_seconds 1.7e+09
# HELP node_reboot_required Node reboot is required for software updates.
# TYPE node_reboot_required gauge
node_reboot_required 1
EOF
  local port=$(( 20000 + RANDOM % 20000 ))
  local dirs=(--collector.textfile.directory="$d/own")
  [[ $ARM == onedir ]] || dirs+=(--collector.textfile.directory="$d/collectors")
  "$bin" --web.listen-address=127.0.0.1:"$port" --collector.disable-defaults --collector.textfile \
    "${dirs[@]}" >"$d/exporter.log" 2>&1 &
  pid=$!
  local i m=''
  for i in $(seq 1 25); do m=$(curl -fs --max-time 2 "http://127.0.0.1:$port/metrics") && [[ -n $m ]] && break; sleep 0.2; done
  # an answer from some other program on that port is not ours: the exporter we started must still be running
  kill -0 "$pid" 2>/dev/null && [[ -n $m ]] || { echo "node_exporter did not answer on $port:"; cat "$d/exporter.log"; exit 2; }
  echo "node_exporter on 127.0.0.1:$port, $([[ $ARM == onedir ]] && echo 'its own directory only' || echo 'both directories')"
  has() { grep -qE "^$1" <<<"$m"; }
  if has 'estate_check_ok\{check="example"\} 1'; then ok own "the machine's own fact is served"; else fail own "the machine's own fact is not served"; fi
  if has 'apt_upgrades_pending\{.*security.*\} 2'; then ok pending "pending security updates are served"; else fail pending "pending security updates are not served"; fi
  if has 'apt_package_cache_timestamp_seconds '; then ok lists "the package lists' age is served"; else fail lists "the package lists' age is not served"; fi
  if has 'node_reboot_required 1'; then ok reboot "a waiting reboot is served"; else fail reboot "a waiting reboot is not served"; fi
}

drill_rules() {
  command -v promtool >/dev/null || { echo "promtool is required" >&2; exit 2; }
  [[ -f $HERE/patching.yml && -f $HERE/patching.test.yml ]] || { echo "patching.yml and patching.test.yml must be beside this script" >&2; exit 2; }
  [[ -z $ARM ]] || { echo "rules carries its arms inside; run it without ARM" >&2; exit 2; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/drill-patching.XXXXXX")
  trap 'rm -rf "$d"' EXIT
  promtool check rules "$HERE/patching.yml" >/dev/null || { echo "promtool refuses patching.yml"; exit 2; }
  # each case: a copy of the rules, and whether its tests must pass
  run_case() {   # $1 name, $2 sed expression applied to the rules ('' for none), $3 pass|fail
    mkdir -p "$d/$1"
    if [[ -n $2 ]]; then sed -E "$2" "$HERE/patching.yml" >"$d/$1/patching.yml"; else cp "$HERE/patching.yml" "$d/$1/"; fi
    cmp -s "$HERE/patching.yml" "$d/$1/patching.yml" && [[ -n $2 ]] && { echo "case $1 changed nothing in the rules"; exit 2; }
    cp "$HERE/patching.test.yml" "$d/$1/"
    if promtool test rules "$d/$1/patching.test.yml" >"$d/$1/out" 2>&1; then got=pass; else got=fail; fi
    if [[ $got == "$3" ]]; then ok "$1" "$1: the tests $got, as they must"; else fail "$1" "$1: the tests $got, not $3"; sed 's/^/      /' "$d/$1/out" | head -20; fi
  }
  run_case as-published '' pass
  # no waiting period: an update released after the night's run is reported at once, so the quiet case fails
  run_case no-wait '/alert: SecurityUpdatesUnapplied/,/^ +for: /{s/^( +)for: 3d$/\1for: 0s/}' fail
  # no uptime guard: every box that needs a reboot is reported, including one inside its monthly slot
  run_case no-uptime-guard 's/^( *)and on \(instance\) \(time\(\) - max by \(instance\) \(node_boot_time_seconds\)\) > 37 \* 86400$/\1/' fail
  # no age threshold: fresh lists are reported as stale
  run_case no-list-age '/alert: AptListsStale/,/^ +for: /{s/> 2 \* 86400/> 0/}' fail
  # no write-age threshold: a file written a minute ago is reported as stale
  run_case no-write-age '/alert: PatchFactsStale/,/^ +for: /{s/> 2 \* 3600/> 0/}' fail
  # no `unless`: every machine that answers is reported, the ones that serve the facts included
  run_case no-unless 's/ unless on \(instance\) apt_package_cache_timestamp_seconds$//' fail
}

drill_machine() {
  command -v apt-config >/dev/null || { echo "apt-config is required: this mode is for a Debian-family machine" >&2; exit 2; }
  [[ -z $ARM ]] || { echo "machine has no arm" >&2; exit 2; }
  dpkg -s unattended-upgrades >/dev/null 2>&1 && ok uu "unattended-upgrades is installed" || fail uu "unattended-upgrades is not installed"
  local cfg; cfg=$(apt-config dump)
  grep -q '^APT::Periodic::Unattended-Upgrade "1";' <<<"$cfg" && ok nightly "it runs nightly" || fail nightly "APT::Periodic::Unattended-Upgrade is not 1"
  grep -q '^APT::Periodic::Update-Package-Lists "1";' <<<"$cfg" && ok lists "the lists refresh nightly" || fail lists "APT::Periodic::Update-Package-Lists is not 1"
  grep -q '^Unattended-Upgrade::Automatic-Reboot "false";' <<<"$cfg" && ok noreboot "it never reboots by itself" \
    || fail noreboot "Automatic-Reboot is not explicitly false (unset is false today; declare it)"
  # a security origin is one whose label is Debian-Security, or whose archive or codename ends in -security
  local origins bad; origins=$(grep -E '^Unattended-Upgrade::(Origins-Pattern|Allowed-Origins)::' <<<"$cfg")
  bad=$(grep -vE 'label=Debian-Security|(archive|codename)=[^,"]*-security|:[^"]*-security"' <<<"$origins")
  if [[ -n $origins && -z $bad ]]; then ok origins "every origin it takes is a security origin"
  else fail origins "an origin that is not a security one is allowed: ${bad:-none declared}"; fi
  local f=/var/lib/prometheus/node-exporter/apt.prom
  if [[ -f $f ]] && (( $(date +%s) - $(stat -c %Y "$f") < 3600 )); then ok fresh "$f was written in the last hour"
  else fail fresh "$f is missing or older than an hour: the collectors' timer (every 15 minutes) is not running"; fi
  # ask the exporter where it listens, as configured; EXPORTER=host:port overrides
  local at=${EXPORTER:-$(grep -oE -- '--web\.listen-address=[^ "]+' /etc/default/prometheus-node-exporter 2>/dev/null | head -1 | cut -d= -f2)}
  at=${at:-:9100}
  [[ $at == :* ]] && at=127.0.0.1$at   # ":9100" listens everywhere; ask loopback
  if m=$(curl -fs --max-time 3 "http://$at/metrics" 2>/dev/null) && [[ -n $m ]]; then
    grep -q '^apt_package_cache_timestamp_seconds ' <<<"$m" && ok served "the exporter at $at serves the patch facts" \
      || fail served "the exporter at $at answers but does not serve the patch facts: it does not read the collectors' directory"
  else
    echo "      (no exporter answered at $at; the exporter check is skipped, not passed)"
  fi
}

case ${1:-local} in
  local)   drill_local ;;
  rules)   drill_rules ;;
  machine) drill_machine ;;
  *)       sed -n '2,12p' "$0"; exit 2 ;;
esac

if [[ $ARM == onedir ]]; then
  # The three patch facts live in the collectors' directory; the machine's own fact does not, and must still pass.
  if [[ "${failed[*]}" == "pending lists reboot" ]]; then echo "ARM: exactly the 3 patch-fact checks failed with one directory, as they must"; exit 0; fi
  echo "ARM: the checks that failed with one directory were '${failed[*]}', not 'pending lists reboot': the drill cannot see what it is for"; exit 1
fi
(( fails == 0 )) || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
