#!/usr/bin/env bash
# drill-recovery.sh: a dataset comes back, byte for byte, from the off-site copy alone, with only the carried password.
#
#   ./drill-recovery.sh                     # back up, copy off site, lose the machine, restore from the copy; every check must pass
#   ARM=lostpassword ./drill-recovery.sh    # the carried password is lost: exactly the off-site check and the restore must FAIL
#   Exit codes, the same in every neenv drill: 0 the run proved what it set out to (no ARM: every check passed;
#   an ARM: exactly that arm's checks failed); 1 it did not; 2 it could not run (a missing tool, a setup step).
#
# Needs bash, restic (0.14 or later, for `init --copy-chunker-params`), sha256sum and python3. No network: both repositories
# are directories here, standing for the home store and the off-site twin.
set -u
set -o pipefail

ARM=${ARM:-}
fails=0
failed=()
ok()   { printf 'ok    %s\n' "${*:2}"; }
fail() { printf 'FAIL  %s\n' "${*:2}"; fails=$((fails + 1)); failed+=("$1"); }

command -v restic >/dev/null && command -v sha256sum >/dev/null && command -v python3 >/dev/null || { echo "restic, sha256sum and python3 are required" >&2; exit 2; }
[[ -z $ARM || $ARM == lostpassword ]] || { echo "ARM must be empty or lostpassword" >&2; exit 2; }
d=$(mktemp -d "${TMPDIR:-/tmp}/drill-recovery.XXXXXX") || exit 2
[[ -n $d && -d $d && $d != / ]] || { echo "no scratch directory" >&2; exit 2; }   # every rm below is under $d
trap 'rm -rf "$d"' EXIT
export RESTIC_CACHE_DIR="$d/cache"     # the restore must not lean on a cache the lost machine had
unset RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND

# the machine: one dataset (a database dump stands in), and the repository password, which is also CARRIED elsewhere
mkdir -p "$d/machine/dump"
{ echo "-- example dump"; for i in $(seq 1 500); do echo "INSERT INTO t VALUES ($i, 'row $i $RANDOM');"; done; } >"$d/machine/dump/app.sql"
head -c 32 /dev/urandom | base64 >"$d/machine/restic.pass"
cp "$d/machine/restic.pass" "$d/carried.pass"            # the copy kept outside the estate (the pattern's three secrets)
want=$(sha256sum <"$d/machine/dump/app.sql" | cut -d' ' -f1)

{
  restic init --repo "$d/home" --password-file "$d/machine/restic.pass"
  restic backup --repo "$d/home" --password-file "$d/machine/restic.pass" --host web1 --tag app "$d/machine/dump"
  # the off-site twin: same chunker, so a copy is deduplicated; the same password here, which is what makes one carried
  # secret enough
  restic init --repo "$d/offsite" --password-file "$d/machine/restic.pass" \
    --from-repo "$d/home" --from-password-file "$d/machine/restic.pass" --copy-chunker-params
  restic copy --repo "$d/offsite" --password-file "$d/machine/restic.pass" \
    --from-repo "$d/home" --from-password-file "$d/machine/restic.pass"
} >"$d/setup.log" 2>&1 || { echo "setup failed:"; tail -20 "$d/setup.log"; exit 2; }

# the disaster: the machine and the home store are gone
rm -rf "$d/machine" "$d/home" "$d/cache"
echo "machine and home store removed; recovering from the off-site copy with the carried password"

pass="$d/carried.pass"
if [[ $ARM == lostpassword ]]; then head -c 32 /dev/urandom | base64 >"$d/guess.pass"; pass="$d/guess.pass"; fi

n=$(restic snapshots --repo "$d/offsite" --password-file "$pass" --json 2>"$d/snapshots.err" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)
if [[ $n == 1 ]]; then ok offsite "the off-site copy holds the snapshot, read with the carried password"
else fail offsite "the off-site copy could not be read: $(tail -1 "$d/snapshots.err")"; fi
mkdir -p "$d/restored"
if restic restore latest --repo "$d/offsite" --password-file "$pass" --target "$d/restored" >"$d/restore.log" 2>&1 \
   && got=$(find "$d/restored" -name app.sql -exec sha256sum {} + | cut -d' ' -f1) && [[ $got == "$want" ]]; then
  ok restore "the dataset is restored byte for byte from the off-site copy"
else fail restore "the dataset did not come back: $(tail -1 "$d/restore.log")"; fi

if [[ $ARM == lostpassword ]]; then
  # and they failed for the right reason: a wrong password, not a damaged or empty repository
  if [[ "${failed[*]}" == "offsite restore" ]] && grep -q 'wrong password' "$d/snapshots.err" "$d/restore.log"; then
    echo "ARM: exactly the off-site read and the restore failed, for a wrong password, as they must"; exit 0; fi
  echo "ARM: the checks that failed were '${failed[*]}', not 'offsite restore'"; exit 1
fi
(( fails == 0 )) || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
