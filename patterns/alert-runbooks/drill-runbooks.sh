#!/usr/bin/env bash
# drill-runbooks.sh: every alert says what a person does first, and the check that says so can fail.
#
#   ./drill-runbooks.sh                    # three example alerts, each with summary, description and action; the check passes
#   ARM=noaction ./drill-runbooks.sh       # one alert loses its action: exactly that one alert must be named
#   ./drill-runbooks.sh check FILE...      # run the check on your own rule files
#   Exit codes, the same in every neenv drill: 0 the run proved what it set out to; 1 it did not; 2 it could not run.
#
# Needs bash and python3 with PyYAML (Debian: python3-yaml).
set -u
set -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ARM=${ARM:-}
python3 -c 'import yaml' 2>/dev/null || { echo "python3 with PyYAML is required" >&2; exit 2; }
if [[ ${1:-} == check ]]; then shift; exec python3 "$HERE/check-alert-actions.py" "$@"; fi
[[ -z $ARM || $ARM == noaction ]] || { echo "ARM must be empty or noaction" >&2; exit 2; }
d=$(mktemp -d "${TMPDIR:-/tmp}/drill-runbooks.XXXXXX") || exit 2
trap 'rm -rf "$d"' EXIT
cat >"$d/rules.yml" <<'RULES'
groups:
  - name: example
    rules:
      - alert: DiskSpaceLow
        expr: (1 - node_filesystem_avail_bytes / node_filesystem_size_bytes) > 0.8
        annotations:
          summary: "{{ $labels.instance }}: disk {{ $labels.mountpoint }} over 80%"
          description: "Disk usage is above 80% on {{ $labels.instance }} ({{ $labels.mountpoint }})."
          action: "Run `du -xh --max-depth=2 <mountpoint> | sort -h | tail` and remove or move what grew."
      - alert: InstanceDown
        expr: up == 0
        annotations:
          summary: "{{ $labels.instance }} is down"
          description: "{{ $labels.instance }} has not answered its scrape for 2 minutes."
          action: "Reach the machine another way (its console, its other address); if it answers, read its network."
      - alert: BackupStale
        expr: time() - backup_last_success_timestamp_seconds > 172800
        annotations:
          summary: "backup {{ $labels.job }} is two days old"
          description: "The backup has not succeeded in 48 hours."
          action: "Read the backup job's last runs, fix the cause, and run it once by hand."
RULES
[[ $ARM == noaction ]] && sed -i '/action: "Reach the machine/d' "$d/rules.yml"
out=$(python3 "$HERE/check-alert-actions.py" "$d/rules.yml"); rc=$?
echo "$out"
if [[ $ARM == noaction ]]; then
  if (( rc == 1 )) && grep -q "InstanceDown lacks action" <<<"$out" && [[ $(grep -c ' lacks ' <<<"$out") == 1 ]]; then
    echo "ARM: exactly the alert without an action was named, as it must"; exit 0; fi
  echo "ARM: the check did not name exactly InstanceDown (rc $rc)"; exit 1
fi
(( rc == 0 )) && { echo "all checks passed"; exit 0; }
exit 1
