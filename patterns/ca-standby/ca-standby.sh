#!/bin/bash
# ca-standby.sh — a step-ca's cold standby: its copy, its check, its switch, its fence. Published from a working
# script with its names made parameters (neenv patterns/ca-standby; README.md says how it is used and what it checks).
#
#   ca-standby.sh copy   --from <primary> --to <standby> [--force]
#                        the CA's directory without its password files or a root key; the database copied while step-ca
#                        is frozen (SIGSTOP, bounded, thawed by trap and by a detached watchdog); staged, verified against
#                        a trailer (a stamp and every file's sha256), refused onto a host that could be a CA or holds
#                        newer data, installed only when both ends succeeded
#   ca-standby.sh check  --from <primary> --to <standby> [--max-age-hours 26]
#                        files equal, the copy fresh, no password file, stopped and disabled, the database opens (a
#                        throwaway `step ca init` in a scratch directory, pointed at a scratch copy of the database)
#   ca-standby.sh switch --from <old> --to <standby> [--from-down]
#                        check both password items, fence, last copy, then under one lock compare the intermediate on
#                        disk, unlock and start; probe; rolls back on failure and says so
#   ca-standby.sh fence  --host <host>                       an old primary that comes back after --from-down
#   ca-standby.sh receive --to <standby> [--force] < stream  stage, verify and install one copy stream
#
# Settings (environment):
#   CA_NAME (ca.example.internal), CA_PORT (9000), CA_DIR (/etc/step-ca), CA_UNIT (step-ca), CA_FREEZE_TIMEOUT (60)
#   CA_SSH_USER (admin), CA_SSH_KEY (~/.ssh/id_ed25519), CA_SSH_OPTS — ssh as a user with passwordless sudo
#   CA_PW_CMD     a command printing one secret given an item name (your password manager's reader); required to switch
#   CA_KEY_ITEM, CA_PROV_ITEM   the items holding the key password and the provisioner password
#   CA_PRESENTED  the intermediate certificate your CA must present (the file you install as ca.json's crt); required
#                 to switch
#   CA_DOCKER=1   hosts are container names on this machine (the drill)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=${CA_DIR:-/etc/step-ca}
UNIT=${CA_UNIT:-step-ca}
NAME=${CA_NAME:-ca.example.internal}
PORT=${CA_PORT:-9000}
SSH_USER=${CA_SSH_USER:-admin}
SSH_KEY=${CA_SSH_KEY:-$HOME/.ssh/id_ed25519}
KEY_ITEM=${CA_KEY_ITEM:-step-ca key password}
PROV_ITEM=${CA_PROV_ITEM:-step-ca provisioner password}
FREEZE_TIMEOUT=${CA_FREEZE_TIMEOUT:-60}
MAX_AGE_H=26; FROM_DOWN=0; FORCE=0
usage() { echo "usage: ca-standby.sh copy|check|switch --from <host> --to <host> [--from-down] [--force] [--max-age-hours N]"
          echo "       ca-standby.sh fence --host <host>     ca-standby.sh receive --to <host> [--force] < stream"; exit 2; }
need() { [ $# -ge 2 ] && [ -n "$2" ] && [ "${2#--}" = "$2" ] || { echo "$1 needs a value"; usage; }; }
VERB=${1:-}; shift || true
while [ $# -gt 0 ]; do case "$1" in
  --from|--to|--host|--max-age-hours) need "$@"; case "$1" in --from) FROM=$2 ;; --to) TO=$2 ;; --host) HOST=$2 ;;
                                      --max-age-hours) MAX_AGE_H=$2 ;; esac; shift 2 ;;
  --from-down) FROM_DOWN=1; shift ;; --force) FORCE=1; shift ;;
  *) echo "unknown argument: $1"; usage ;; esac; done

docker_cmd() { if docker info >/dev/null 2>&1; then docker "$@"; else sudo -n docker "$@"; fi; }
on() {  # on <host> <bash program> — one root bash on a host; stdin passes through; the program travels base64
  local b; b=$(printf '%s' "$2" | base64 -w0)
  if [ -n "${CA_DOCKER:-}" ]; then docker_cmd exec -i "$1" bash -c "$(printf '%s' "$b" | base64 -d)"
  else
    local ssh=(ssh -o BatchMode=yes -o ConnectTimeout=10); [ -r "$SSH_KEY" ] && ssh+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
    [ -n "${CA_SSH_OPTS:-}" ] && ssh+=($CA_SSH_OPTS)
    "${ssh[@]}" "$SSH_USER@$1" "sudo -n bash -c \"\$(echo $b | base64 -d)\""
  fi
}
onn() { on "$@" </dev/null; }   # no input meant: none given
addr_of() {
  if [ -n "${CA_DOCKER:-}" ]; then docker_cmd inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"
  else getent ahostsv4 "$1" | awk 'NR==1{print $1}'; fi
}
pw() {  # pw <item> — one secret on stdout, for a pipe
  [ -n "${CA_PW_CMD:-}" ] || fail "set CA_PW_CMD to a command that prints one secret given its item name"; $CA_PW_CMD "$1"
}
now() { date +%s.%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
fail() { echo "FAIL $*"; exit 1; }
LOCK='exec 9>/run/ca-standby.lock; flock -n 9 || { echo "REFUSED: another ca-standby run holds the lock" >&2; exit 6; }'
# The address step-ca listens on, from ca.json ("host:port"; an empty host is every address, probed on loopback).
LISTEN='a=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(\"address\",\":'"$PORT"'\"))" '"$DIR"'/config/ca.json 2>/dev/null || echo ":'"$PORT"'")
lh=${a%:*}; lp=${a##*:}; [ -n "$lh" ] || lh=127.0.0.1'

# The sender: lock, freeze only for the database copy (bounded; thawed by trap, and by a detached watchdog if the sender
# is killed), stage the rest, write the trailer, one tar on stdout.
SEND="set -euo pipefail; $LOCK"'
D='"$DIR"'; U='"$UNIT"'; FT='"$FREEZE_TIMEOUT"'
t=$(mktemp -d /var/tmp/ca-standby.XXXXXX); w=
thaw() { systemctl kill --signal=CONT "$U" 2>/dev/null || true; [ -z "$w" ] || kill "$w" 2>/dev/null || true; }
trap "thaw; rm -rf $t" EXIT; trap "thaw; rm -rf $t; exit 1" HUP INT TERM
[ ! -e "$D/secrets/root_ca_key" ] || { echo "REFUSED: $D holds the root key; keep it in the password manager, never in the CA directory" >&2; exit 7; }
mkdir -m 0700 "$t/s"
if systemctl is-active -q "$U"; then
  setsid sh -c "sleep $((FT + 10)); systemctl kill --signal=CONT $U" </dev/null >/dev/null 2>&1 9>&- & w=$!
  a=$(date +%s%N); systemctl kill --signal=STOP "$U"; timeout "$FT" cp -a "$D/db" "$t/s/db" 9>&-; thaw; b=$(date +%s%N)
  echo "frozen $(( (b - a) / 1000000 )) ms" >&2
else timeout "$FT" cp -a "$D/db" "$t/s/db" 9>&-; echo "not running: copied without a freeze" >&2; fi
tar -C "$D" --exclude=./password.txt --exclude=./provisioner-password.txt --exclude=./db --exclude=./secrets/root_ca_key \
    --exclude=./.ca-standby-stamp --exclude=./.ca-standby-sums --exclude=./.ca-standby-fenced -cf - . | tar -C "$t/s" -xf -
# The stamp is the time of the DATA: now on a CA (running, or fenced since its last copy); on a standby, the time of the
# copy it holds — so a standby relaying old data cannot pass it off as new.
dt=$(date +%s); src=$(hostname)
if ! systemctl is-active -q "$U" && [ -s "$D/.ca-standby-stamp" ]; then
  st=$(cut -d" " -f1 "$D/.ca-standby-stamp"); fz=0; [ ! -s "$D/.ca-standby-fenced" ] || fz=$(cat "$D/.ca-standby-fenced")
  [ "$fz" -gt "$st" ] || { dt=$st; src="$(cut -d" " -f2- "$D/.ca-standby-stamp") via $src"; }
fi
printf "%s %s\n" "$dt" "$src" > "$t/s/.ca-standby-stamp"
(cd "$t/s" && find . -type f ! -name .ca-standby-sums -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$t/s/.ca-standby-sums"
tar -C "$t/s" -cf - .'

# Could this host be a CA right now? Running, enabled (Restart= or the next boot starts it), or holding a password.
MAYBE_CA='maybe_ca() { systemctl is-active -q "$U" && { echo "step-ca is running here"; return 0; }
  systemctl is-enabled -q "$U" 2>/dev/null && { echo "step-ca is enabled here"; return 0; }
  [ ! -e "$D/password.txt" ] && [ ! -e "$D/provisioner-password.txt" ] || { echo "a password file is here"; return 0; }
  return 1; }'

# The receiver's stage: lock, refuse a host that could be a CA, unpack beside the live copy, verify trailer, contents and
# age against what the receiver already holds.
STAGE="set -euo pipefail; $LOCK; $MAYBE_CA"'
D='"$DIR"'; U='"$UNIT"'; FORCE='"$FORCE"'
if why=$(maybe_ca); then echo "REFUSED: $why; a standby is stopped, disabled and holds no password" >&2; exit 3; fi
rm -rf "$D.new"; mkdir -m 0700 "$D.new"; tar -C "$D.new" -xf -
bad() { rm -rf "$D.new"; echo "REFUSED: $*" >&2; exit 4; }
[ -s "$D.new/.ca-standby-sums" ] && [ -s "$D.new/.ca-standby-stamp" ] || bad "no trailer: the stream was cut or is not a copy"
(cd "$D.new" && sha256sum --quiet -c .ca-standby-sums) >/dev/null 2>&1 || bad "the files do not match the trailer: a cut or altered stream"
n=$(cd "$D.new" && find . -type f ! -name .ca-standby-sums | wc -l); [ "$n" = "$(wc -l < "$D.new/.ca-standby-sums")" ] || bad "files the trailer does not list"
for f in password.txt provisioner-password.txt; do [ ! -e "$D.new/$f" ] || bad "the copy carries $f; a standby never holds the key password"; done
[ ! -e "$D.new/secrets/root_ca_key" ] || bad "the copy carries the root key"
[ -s "$D.new/config/ca.json" ] || bad "the copy has no ca.json"
inc=$(cut -d" " -f1 "$D.new/.ca-standby-stamp"); mine=0
[ ! -s "$D/.ca-standby-stamp" ] || mine=$(cut -d" " -f1 "$D/.ca-standby-stamp")
[ ! -s "$D/.ca-standby-fenced" ] || { f=$(cat "$D/.ca-standby-fenced"); [ "$f" -le "$mine" ] || mine=$f; }
[ ! -d "$D/db" ] || { m=$(find "$D/db" -type f -printf "%T@\n" | sort -n | tail -1 | cut -d. -f1); [ -z "$m" ] || [ "$m" -le "$mine" ] || mine=$m; }
[ "$FORCE" = 1 ] || [ "$inc" -ge "$mine" ] || bad "the copy ($inc) is older than what this host holds ($mine): a wrong-way copy. --force only if that is meant"
chown -R step:step "$D.new"; echo staged'

# Install: only after both ends returned 0; nothing may hold a password afterwards, .prev included.
INSTALL="set -euo pipefail; $LOCK"'
D='"$DIR"'
[ -d "$D.new" ] || { echo "nothing staged" >&2; exit 5; }
rm -rf "$D.prev"; [ ! -d "$D" ] || mv "$D" "$D.prev"; mv "$D.new" "$D"
rm -f "$D/password.txt" "$D/provisioner-password.txt" "$D.prev/password.txt" "$D.prev/provisioner-password.txt"; echo installed'
DISCARD="$LOCK"'; rm -rf '"$DIR"'.new'

MANIFEST='cd '"$DIR"' && find . -path ./db -prune -o -type f ! -name password.txt ! -name provisioner-password.txt ! -name ".ca-standby-*" -print | LC_ALL=C sort | xargs -r sha256sum'
STATE='D='"$DIR"'; U='"$UNIT"'; '"$LISTEN"'
systemctl is-active -q "$U" && echo "unit=running" || echo "unit=stopped"
systemctl is-enabled -q "$U" 2>/dev/null && echo "enabled=yes" || echo "enabled=no"
[ -e "$D/password.txt" ] || [ -e "$D/provisioner-password.txt" ] && echo "password=present" || echo "password=absent"
(exec 3<>/dev/tcp/$lh/$lp) 2>/dev/null && echo "port=open" || echo "port=closed"'
FENCED=$(printf 'unit=stopped\nenabled=no\npassword=absent\nport=closed')
FENCE='D='"$DIR"'; U='"$UNIT"'
# a host that was a CA records when it stopped being one: no copy older than this may land on it (a wrong-way copy)
if systemctl is-active -q "$U" || systemctl is-enabled -q "$U" 2>/dev/null || [ -e "$D/password.txt" ]; then date +%s > "$D/.ca-standby-fenced"; fi
systemctl disable --now "$U" >/dev/null 2>&1 || true; rm -f "$D/password.txt" "$D/provisioner-password.txt"'
ROLLBACK="$FENCE"

# The database: its type from ca.json; a badger directory must hold data and OPEN in a throwaway step-ca.
OPENS='set -u
D='"$DIR"'
ty=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(\"db\",{}).get(\"type\",\"\"))" "$D/config/ca.json")
case "$ty" in badger*) ;; *) echo "database type ${ty:-none}: not a file copy this script can check"; exit 1 ;; esac
[ "$(find "$D/db" -type f \( -name "*.vlog" -o -name "*.sst" \) -size +0 | wc -l)" -gt 0 ] || { echo "the database holds no data files"; exit 1; }
t=$(mktemp -d /var/tmp/ca-standby-open.XXXXXX); p=; trap "[ -n \"\$p\" ] && kill \$p 2>/dev/null; rm -rf $t" EXIT
cp -a "$D/db" $t/db; head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n" > $t/pw
STEPPATH=$t/s step ca init --name probe --dns localhost --address 127.0.0.1:19309 --provisioner probe \
  --password-file $t/pw --provisioner-password-file $t/pw --deployment-type standalone >/dev/null 2>&1 || { echo "throwaway init failed"; exit 1; }
python3 -c "import json,sys;p=sys.argv[1];c=json.load(open(p));c[\"db\"]={\"type\":sys.argv[3],\"dataSource\":sys.argv[2]};json.dump(c,open(p,\"w\"))" $t/s/config/ca.json $t/db "$ty"
STEPPATH=$t/s step-ca $t/s/config/ca.json --password-file $t/pw > $t/log 2>&1 & p=$!
for i in $(seq 1 20); do curl -sk --max-time 3 https://127.0.0.1:19309/health 2>/dev/null | grep -q ok && { echo opens; exit 0; }; kill -0 $p 2>/dev/null || break; sleep 0.5; done
echo "does not open: $(tail -3 $t/log | tr "\n" " ")"; exit 1'

# Step 3, under one lock on the standby: compare the intermediate on disk, then (stdin: two base64 lines, the key
# password and the provisioner password) write the files and start. Exit 10 = not as declared, nothing written.
UNLOCK_START="set -uo pipefail; $LOCK"'
D='"$DIR"'; U='"$UNIT"'
c=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[\"crt\"])" "$D/config/ca.json"); case "$c" in /*) ;; *) c="$D/$c" ;; esac
disk=$(openssl x509 -in "$c" -noout -fingerprint -sha256 2>/dev/null)
[ -n "$disk" ] && [ "$disk" = "$WANT" ] || { echo "the copy names intermediate ${disk:-none}, not the declared one: refused before unlock, nothing written" >&2; exit 10; }
read -r k; read -r p
umask 077; printf "%s" "$k" | base64 -d > "$D/password.txt"; printf "%s" "$p" | base64 -d > "$D/provisioner-password.txt"
chown step:step "$D/password.txt" "$D/provisioner-password.txt"
[ -s "$D/password.txt" ] && [ -s "$D/provisioner-password.txt" ] || { echo "a password came through empty" >&2; exit 11; }
systemctl enable --now "$U" >/dev/null 2>&1 9>&-; systemctl is-active -q "$U" || { echo "step-ca did not start" >&2; exit 12; }
'"$LISTEN"'; echo "listen=$lh:$lp"'

state_of() {  # state_of <host> — the four answers, or FAIL if the host did not give them all
  local s; s=$(onn "$1" "$STATE") || fail "cannot read $1's state"
  for k in unit enabled password port; do echo "$s" | grep -q "^$k=" || fail "$1 gave no complete state: $(echo $s)"; done
  echo "$s"
}
fence_host() {  # fence_host <host> — stopped, disabled, no password, port refusing, each re-read; FAIL otherwise
  onn "$1" "$FENCE" || fail "could not reach $1 to fence it"
  local s; s=$(state_of "$1") || exit 1
  [ "$s" = "$FENCED" ] || fail "$1 is not fenced: $(echo $s)"
}
copy_to() {  # copy_to <from> <to> — send | stage, then install only if both returned 0
  onn "$1" "$SEND" | on "$2" "$STAGE" >/dev/null; local rc=("${PIPESTATUS[@]}")
  if [ "${rc[0]}" != 0 ] || [ "${rc[1]}" != 0 ]; then onn "$2" "$DISCARD" >/dev/null 2>&1; fail "copy $1 -> $2 (send rc ${rc[0]}, stage rc ${rc[1]}); the standby's previous copy stands"; fi
  onn "$2" "$INSTALL" >/dev/null || fail "install on $2"
}
rollback() {  # rollback <host> — stop, disable, delete passwords; then SAY what the host is, from a fresh read
  onn "$1" "$ROLLBACK" >/dev/null 2>&1; local rc=$? s
  s=$(state_of "$1" 2>&1); local src=$?
  if [ $rc = 0 ] && [ $src = 0 ] && echo "$s" | grep -qx 'unit=stopped' && echo "$s" | grep -qx 'enabled=no' && echo "$s" | grep -qx 'password=absent'
  then echo "   ROLLBACK on $1: $(echo $s)"
  else echo "   ROLLBACK FAILED on $1 (rc $rc): $(echo $s) — stop it by hand: systemctl disable --now $UNIT; rm -f $DIR/password.txt $DIR/provisioner-password.txt"; fi
}

case "$VERB" in
copy)
  [ -n "${FROM:-}" ] && [ -n "${TO:-}" ] && [ "$FROM" != "$TO" ] || usage
  T0=$(now); copy_to "$FROM" "$TO"; echo "copied $FROM -> $TO in $(secs "$T0" "$(now)") s"; echo "PASS copy" ;;
receive)
  [ -n "${TO:-}" ] || usage
  on "$TO" "$STAGE" || exit 1; onn "$TO" "$INSTALL" || exit 1; echo "PASS receive" ;;
fence)
  [ -n "${HOST:-}" ] || usage
  fence_host "$HOST"; echo "PASS fence $HOST: stopped, disabled, no password file, its port refusing" ;;
check)
  [ -n "${FROM:-}" ] && [ -n "${TO:-}" ] && [ "$FROM" != "$TO" ] || usage
  a=$(onn "$FROM" "$MANIFEST") || fail "cannot read $FROM"; b=$(onn "$TO" "$MANIFEST") || fail "cannot read $TO"
  [ -n "$a" ] && [ "$a" = "$b" ] || fail "the standby's files differ from the primary's: $(diff <(echo "$a") <(echo "$b") | head -4 | tr '\n' ' ')"
  echo "ok   $(echo "$a" | wc -l) files equal (database aside)"
  st=$(onn "$TO" "cat $DIR/.ca-standby-stamp") || fail "cannot read the standby's stamp"
  ages=$(( $(date +%s) - ${st%% *} ))
  [ "$ages" -ge -300 ] || fail "the standby's stamp is $(( -ages )) s in the future: a clock is wrong"
  [ $(( ages / 3600 )) -le "$MAX_AGE_H" ] || fail "the standby's copy is $(( ages / 3600 )) h old (limit $MAX_AGE_H h)"
  echo "ok   the copy is $(( ages / 3600 )) h old, from ${st#* }"
  s=$(state_of "$TO") || exit 1
  echo "$s" | grep -qx 'password=absent' || fail "the standby holds a password file"
  echo "ok   the standby holds no password file"
  echo "$s" | grep -qx 'unit=stopped' && echo "$s" | grep -qx 'enabled=no' || fail "step-ca is running or enabled on the standby: $(echo $s)"
  echo "ok   step-ca stopped and disabled on the standby"
  o=$(onn "$TO" "$OPENS"); [ "$o" = opens ] || fail "the standby's database: $o"
  echo "ok   the standby's database holds data and opens in a throwaway step-ca"
  echo "PASS check" ;;
switch)
  [ -n "${FROM:-}" ] && [ -n "${TO:-}" ] && [ "$FROM" != "$TO" ] || usage
  PRESENTED=${CA_PRESENTED:-}; [ -n "$PRESENTED" ] || fail "set CA_PRESENTED to the intermediate certificate your CA presents"
  want=$(openssl x509 -in "$PRESENTED" -noout -fingerprint -sha256 2>/dev/null) || fail "cannot read the declared intermediate $PRESENTED"
  echo "== 0 the two password items"
  for it in "$KEY_ITEM" "$PROV_ITEM"; do
    n=$(pw "$it" 2>/dev/null | wc -c); [ "$n" -gt 0 ] || fail "the item '$it' gave nothing: nothing touched"; done
  echo "   both non-empty"
  T0=$(now)
  echo "== 1 fence $FROM"
  if onn "$FROM" true 2>/dev/null; then
    fence_host "$FROM"; echo "   $FROM fenced ($(secs "$T0" "$(now)") s)"
    echo "== 2 copy (the fenced primary is quiet, so this copy is final)"
    T=$(now); copy_to "$FROM" "$TO"; echo "   copied ($(secs "$T" "$(now)") s)"
  else
    [ "$FROM_DOWN" = 1 ] || fail "$FROM does not answer: refused, because it may still be signing. Say --from-down only when it is known down"
    echo "   $FROM down (--from-down); the standby's last copy stands. FENCE IT WHEN IT RETURNS: ca-standby.sh fence --host $FROM"
  fi
  echo "== 3 compare, unlock and start on $TO (one lock)"
  trap 'rollback "$TO"' EXIT
  out=$( { pw "$KEY_ITEM" | base64 -w0; echo; pw "$PROV_ITEM" | base64 -w0; echo; } | on "$TO" "WANT='$want'; $UNLOCK_START" 2>&1 ); rc=$?
  if [ $rc = 10 ]; then trap - EXIT; fail "$out"; fi
  [ $rc = 0 ] || fail "step 3 on $TO (rc $rc): $out"
  L=$(echo "$out" | sed -n 's/^listen=//p'); LH=${L%:*}; LP=${L##*:}
  case "$LH" in 127.*|localhost|0.0.0.0|"") A=$(addr_of "$TO") ;; *) A=$LH ;; esac; [ -n "$LP" ] || LP=$PORT
  echo "   started; listening on $L"
  echo "== 4 probe $NAME:$LP at $A"
  ok=0
  for i in $(seq 1 30); do curl -sk --max-time 5 --resolve "$NAME:$LP:$A" "https://$NAME:$LP/health" 2>/dev/null | grep -q '"ok"' && { ok=1; break; }; sleep 1; done
  [ $ok = 1 ] || fail "https://$NAME:$LP/health did not answer ok at $A"
  got=$(echo | timeout 10 openssl s_client -connect "$A:$LP" -servername "$NAME" -showcerts 2>/dev/null \
        | awk '/BEGIN CERT/{n++} n==2' | sed -n '/BEGIN CERT/,/END CERT/p' | openssl x509 -noout -fingerprint -sha256 2>/dev/null)
  [ -n "$got" ] && [ "$got" = "$want" ] || fail "$TO serves intermediate ${got:-none}; declared: $want"
  trap - EXIT
  echo "   /health ok, intermediate as declared"
  echo "THE NAME AND THE GROUPS ARE A PERSON'S ACT: point $NAME at $TO, and exchange the two hosts between your CA and"
  echo "standby groups in configuration management in the same change, so applying it cannot start $FROM again."
  echo "PASS switch in $(secs "$T0" "$(now)") s" ;;
*) usage ;;
esac
