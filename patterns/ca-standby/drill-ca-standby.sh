#!/bin/bash
# drill-ca-standby.sh — the cold standby rehearsed on two throwaway containers (neenv patterns/ca-standby).
#   ./drill-ca-standby.sh        needs Docker (docker, or sudo -n docker) and network access to build the image once
# P runs a throwaway step-ca, S is an empty standby; ca-standby.sh runs against them unchanged, through docker exec and
# once through sshd as a user whose login shell is dash. Then each guard is removed from a copy of the script, one at a
# time, and the case named for that guard must fail. CA_DRILL_CASES_ONLY=1 runs the cases without the arms.
# Exit 0: every case as expected and every arm red on its own case. 1: not. 2: it could not run.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); SCRIPT=${CA_STANDBY_SCRIPT:-$HERE/ca-standby.sh}
dk() { if docker info >/dev/null 2>&1; then docker "$@"; else sudo -n docker "$@"; fi; }
dk info >/dev/null 2>&1 || { echo "cannot run: no Docker (docker, or sudo -n docker)"; exit 2; }
IMG=ca-standby-drill:4; NET=ca-standby-drill-$$; P=ca-standby-p-$$; S=ca-standby-s-$$; CN=ca.example.internal
W=$(mktemp -d); trap 'dk rm -f $P $S >/dev/null 2>&1; dk network rm $NET >/dev/null 2>&1; rm -rf "$W"' EXIT
dk build -q -t $IMG "$HERE" >/dev/null || { echo "cannot run: the image did not build"; exit 2; }
rnd() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
rnd > "$W/key.pw"; rnd > "$W/prov.pw"; rnd > "$W/wrong.pw"
# two passwords, chosen by item name, so a script that writes one item into both files is caught
printf '#!/bin/sh\ncase "$1" in "drill key item") cat %s ;; "drill provisioner item") cat %s ;; *) exit 1 ;; esac\n' "$W/key.pw" "$W/prov.pw" > "$W/pwcmd"
printf '#!/bin/sh\ncase "$1" in "drill key item") cat %s ;; *) cat %s ;; esac\n' "$W/wrong.pw" "$W/prov.pw" > "$W/pwcmd-wrong"
printf '#!/bin/sh\ncase "$1" in "drill key item") : ;; *) cat %s ;; esac\n' "$W/prov.pw" > "$W/pwcmd-empty"
chmod +x "$W"/pwcmd*
ssh-keygen -q -t ed25519 -N '' -f "$W/ssh" >/dev/null
export CA_DOCKER=1 CA_PW_CMD="$W/pwcmd" CA_PRESENTED="$W/presented.pem" CA_NAME=$CN CA_FREEZE_TIMEOUT=5 \
       CA_KEY_ITEM="drill key item" CA_PROV_ITEM="drill provisioner item"

up() {  # fresh P (a running throwaway CA, as configuration management leaves the CA) and an empty S
  dk rm -f $P $S >/dev/null 2>&1; dk network rm $NET >/dev/null 2>&1; dk network create $NET >/dev/null
  for c in $P $S; do dk run -d --name $c --network $NET --add-host $CN:127.0.0.1 $IMG >/dev/null
    dk exec -i $c sh -c 'cat > /home/ca/.ssh/authorized_keys; chown ca:ca /home/ca/.ssh/authorized_keys' < "$W/ssh.pub"; done
  cat "$W/key.pw" "$W/prov.pw" | dk exec -i $P bash -c 'mkdir -m 700 /etc/step-ca; head -c 48 > /etc/step-ca/password.txt; cat > /etc/step-ca/provisioner-password.txt
    STEPPATH=/etc/step-ca step ca init --name "Drill CA" --dns '$CN' --address :9000 --provisioner drill \
      --password-file /etc/step-ca/password.txt --provisioner-password-file /etc/step-ca/provisioner-password.txt --deployment-type standalone >/dev/null 2>&1
    cp /etc/step-ca/certs/intermediate_ca.crt /etc/step-ca/certs/intermediate_chain.crt
    python3 -c "import json;p=\"/etc/step-ca/config/ca.json\";c=json.load(open(p));c[\"crt\"]=\"/etc/step-ca/certs/intermediate_chain.crt\";json.dump(c,open(p,\"w\"))"
    rm -f /etc/step-ca/secrets/root_ca_key; chown -R step:step /etc/step-ca; systemctl enable --now step-ca'
  dk exec $S sh -c 'mkdir -m 700 /etc/step-ca; chown step:step /etc/step-ca'
  dk exec $P cat /etc/step-ca/certs/intermediate_chain.crt > "$W/presented.pem"
}
issue() {  # issue <container> <name> — a certificate from the JWK provisioner (its own password), so the db has rows
  dk exec -i $1 sh -c "cat > /tmp/pw; STEPPATH=/tmp/c timeout 20 step ca certificate $2 /tmp/$2.crt /tmp/$2.key --provisioner drill \
    --password-file /tmp/pw --ca-url https://$CN:9000 --root /etc/step-ca/certs/root_ca.crt -f >/dev/null 2>&1" < "$W/prov.pw"
}
healthy() { dk exec $1 sh -c 'curl -sk --max-time 3 https://127.0.0.1:9000/health | grep -q ok'; }
frozen() { dk exec $1 sh -c 'grep -q "^State:.*T" /proc/$(cat /run/step-ca.pid)/status 2>/dev/null'; }
fenced() { dk exec $1 bash -c '! systemctl is-active -q step-ca && ! systemctl is-enabled -q step-ca && [ ! -e /etc/step-ca/password.txt ] && [ ! -e /etc/step-ca/provisioner-password.txt ] && ! (exec 3<>/dev/tcp/127.0.0.1/9000) 2>/dev/null'; }
stopped_clean() { dk exec $1 bash -c '! systemctl is-active -q step-ca && ! systemctl is-enabled -q step-ca && [ ! -e /etc/step-ca/password.txt ] && [ ! -e /etc/step-ca/provisioner-password.txt ]'; }
unlock_in_place() { dk exec -i $1 sh -c 'head -c 48 > /etc/step-ca/password.txt; cat > /etc/step-ca/provisioner-password.txt; chown step:step /etc/step-ca/*password.txt; systemctl enable --now step-ca' < <(cat "$W/key.pw" "$W/prov.pw"); }
stamp() { dk exec $1 cat /etc/step-ca/.ca-standby-stamp 2>/dev/null; }
wait_for() {  # wait_for <seconds> <command...> — true as soon as the command is
  local n=$1; shift; local i; for i in $(seq 1 $((n * 2))); do "$@" && return 0; sleep 0.5; done; return 1; }
not_frozen() { ! frozen $P; }
stream() {  # stream <name> <python edit> — a copy stream made from S's installed copy, edited, its trailer re-made
  local d="$W/st-$1"; rm -rf "$d"; mkdir -p "$d"; dk exec $S tar -C /etc/step-ca -cf - . | tar -C "$d" -xf - 2>/dev/null
  python3 -c "$2" "$d"
  case "$1" in cut|altered|extra) ;; *) (cd "$d" && rm -f .ca-standby-sums && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$W/sums" && mv "$W/sums" .ca-standby-sums) ;; esac
  tar -C "$d" -cf "$W/$1.tar" .
}

suite() {  # suite <script> — the cases; one line each; returns the number not as expected
  local sc=$1 bad=0
  c() {  # c <rc> <want> <case name>
    if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  BAD  $3 (got $1, want $2)"; bad=$((bad+1))
      [ -s "$W/last" ] && sed 's/^/         | /' "$W/last" | tail -8; fi; : > "$W/last"; }
  x() { "$@" >"$W/last" 2>&1; }   # a script call, its output kept for a BAD line
  up
  { issue $P a.example.test && issue $P b.example.test; }; c $? 0 "P issues"
  x bash "$sc" copy --from $P --to $S; c $? 0 "copy P -> S"
  healthy $P; c $? 0 "P answers after the copy"
  frozen $P; c $? 1 "P is not left stopped"
  x bash "$sc" check --from $P --to $S; c $? 0 "check passes"
  st=$(stamp $S); dk exec $S sh -c "echo '$(( $(date +%s) + 3600 )) future' > /etc/step-ca/.ca-standby-stamp"
  x bash "$sc" check --from $P --to $S; c $? 1 "check refuses a stamp from the future"
  dk exec $S sh -c "echo '$st' > /etc/step-ca/.ca-standby-stamp"
  dk exec $S sh -c 'systemctl start step-ca; systemctl is-active -q step-ca'; c $? 1 "S cannot start by itself"
  # running, but neither enabled nor holding a password (the file goes once the CA has read it): only "running" holds
  dk exec -i $S sh -c 'cat > /etc/step-ca/password.txt; chown step:step /etc/step-ca/password.txt; systemctl start step-ca; rm -f /etc/step-ca/password.txt' < "$W/key.pw"
  x bash "$sc" copy --from $P --to $S; c $? 1 "copy refused while S runs"
  dk exec -i $S sh -c 'systemctl stop step-ca; cat > /etc/step-ca/password.txt' < "$W/key.pw"
  x bash "$sc" copy --from $P --to $S; c $? 1 "copy refused while S holds a password file"
  dk exec $S sh -c 'rm -f /etc/step-ca/password.txt; systemctl enable step-ca'
  x bash "$sc" copy --from $P --to $S; c $? 1 "copy refused while S's unit is enabled"
  dk exec $S sh -c 'systemctl disable step-ca'
  before=$(stamp $S); dk exec $P touch /run/fail-cp
  x bash "$sc" copy --from $P --to $S; r=$?; dk exec $P rm -f /run/fail-cp
  frozen $P; f=$?; [ $r != 0 ] && [ $f = 1 ] && healthy $P; c $? 0 "a failed database copy leaves P thawed"
  [ "$(stamp $S)" = "$before" ]; c $? 0 "a failed copy leaves S's previous copy"
  dk exec $P touch /run/slow-cp
  bash "$sc" copy --from $P --to $S >/dev/null 2>&1 & bg=$!
  wait_for 10 frozen $P && dk exec $P pkill -TERM -f 'ca-standby.XXXXXX'; T=$(date +%s)
  wait_for 9 not_frozen; r=$?; wait $bg 2>/dev/null; c $r 0 "a sender TERMed mid-freeze thaws P at once"
  bash "$sc" copy --from $P --to $S >/dev/null 2>&1 & bg=$!
  wait_for 10 frozen $P && dk exec $P pkill -KILL -f 'ca-standby.XXXXXX'
  wait_for 25 not_frozen; r=$?; dk exec $P rm -f /run/slow-cp; wait $bg 2>/dev/null; c $r 0 "a sender killed mid-freeze is thawed by the watchdog"
  dk exec $S sh -c 'printf "not a badger manifest" > /etc/step-ca/db/MANIFEST'
  x bash "$sc" check --from $P --to $S; c $? 1 "check fails on a database that does not open"
  x bash "$sc" copy --from $P --to $S; c $? 0 "a fresh copy replaces it"
  sleep 2; issue $P d.example.test; x bash "$sc" fence --host $P
  x bash "$sc" copy --from $S --to $P; c $? 1 "a wrong-way copy onto a newer CA is refused"
  unlock_in_place $P; wait_for 10 healthy $P
  stream good 'pass'
  stream cut 'import os,sys; os.remove(os.path.join(sys.argv[1],"config","defaults.json"))'
  stream altered 'import os,sys; open(os.path.join(sys.argv[1],"config","defaults.json"),"a").write(" ")'
  stream extra 'import os,sys; open(os.path.join(sys.argv[1],"config","stray.json"),"w").write("{}")'
  stream pw 'import os,sys; open(os.path.join(sys.argv[1],"password.txt"),"w").write("x")'
  stream nojson 'import os,sys; os.remove(os.path.join(sys.argv[1],"config","ca.json"))'
  stream rootkey 'import os,sys; open(os.path.join(sys.argv[1],"secrets","root_ca_key"),"w").write("x")'
  x bash "$sc" receive --to $S < "$W/cut.tar"; c $? 1 "receive refuses a cut stream"
  x bash "$sc" receive --to $S < "$W/altered.tar"; c $? 1 "receive refuses an altered file"
  x bash "$sc" receive --to $S < "$W/extra.tar"; c $? 1 "receive refuses a file the trailer does not list"
  x bash "$sc" receive --to $S < "$W/pw.tar"; c $? 1 "receive refuses a password file"
  x bash "$sc" receive --to $S < "$W/nojson.tar"; c $? 1 "receive refuses a stream with no ca.json"
  x bash "$sc" receive --to $S < "$W/rootkey.tar"; c $? 1 "receive refuses the root key"
  x bash "$sc" receive --to $S < "$W/good.tar"; c $? 0 "receive accepts a whole stream"
  PA=$(dk inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $P); SA=$(dk inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $S)
  sshenv=(env -u CA_DOCKER CA_SSH_USER=ca CA_SSH_KEY="$W/ssh" CA_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR")
  x "${sshenv[@]}" bash "$sc" copy --from $PA --to $SA; c $? 0 "ssh: copy through sshd, a dash login shell"
  x "${sshenv[@]}" bash "$sc" check --from $PA --to $SA; c $? 0 "ssh: check through sshd"
  x env CA_PW_CMD="$W/pwcmd-empty" bash "$sc" switch --from $P --to $S; r=$?
  healthy $P; h=$?; [ $r != 0 ] && [ $h = 0 ]; c $? 0 "an empty password item stops the switch before the fence"
  x bash "$sc" switch --from $P --to $S; c $? 0 "switch P -> S"
  fenced $P; c $? 0 "P fenced: stopped, disabled, no password, port closed"
  dk exec $S cat /etc/step-ca/password.txt | cmp -s - "$W/key.pw" && dk exec $S cat /etc/step-ca/provisioner-password.txt | cmp -s - "$W/prov.pw"
  c $? 0 "S's two password files hold their own items"
  issue $S c.example.test; c $? 0 "S issues from the same provisioner"
  x bash "$sc" switch --from $S --to $P; c $? 0 "switch back S -> P"
  dk stop $S >/dev/null
  x bash "$sc" switch --from $S --to $P; c $? 1 "switch refused when the old primary does not answer"
  dk start $S >/dev/null; sleep 1
  x bash "$sc" copy --from $P --to $S; dk stop $P >/dev/null
  dk exec -d $S flock /run/ca-standby.lock sleep 12; sleep 1
  x bash "$sc" switch --from $P --to $S --from-down; r=$?; stopped_clean $S; f=$?; [ $r != 0 ] && [ $f = 0 ]
  c $? 0 "step 3 refused while another run holds the standby's lock"
  sleep 12
  x bash "$sc" switch --from $P --to $S --from-down; c $? 0 "switch --from-down onto S"
  dk start $P >/dev/null; sleep 1
  # the old primary comes back and its boot starts a second CA
  dk exec -i $P sh -c 'cat > /etc/step-ca/password.txt; chown step:step /etc/step-ca/password.txt; systemctl enable --now step-ca' < "$W/key.pw"
  x bash "$sc" fence --host $P; r=$?; fenced $P; f=$?; [ $r = 0 ] && [ $f = 0 ]; c $? 0 "a returning host is fenced"
  x env CA_PW_CMD="$W/pwcmd-wrong" bash "$sc" switch --from $S --to $P; r=$?; stopped_clean $P; f=$?
  [ $r != 0 ] && [ $f = 0 ]; c $? 0 "a failed start rolls back"
  dk stop $S >/dev/null
  # P starts but listens where no client reaches it: the probe fails after a successful start
  dk exec $P python3 -c 'import json;p="/etc/step-ca/config/ca.json";c=json.load(open(p));c["address"]="127.0.0.2:9000";json.dump(c,open(p,"w"))'
  x bash "$sc" switch --from $S --to $P --from-down; r=$?; stopped_clean $P; f=$?
  [ $r != 0 ] && [ $f = 0 ] && grep -q 'ROLLBACK on' "$W/last"; c $? 0 "a failed probe after a start rolls back: stopped and disabled"
  # a foreign CA's certificates and key on P: refused before any password is written
  dk exec -i $P sh -c 't=$(mktemp -d); cat > $t/pw; STEPPATH=$t/f step ca init --name Foreign --dns '$CN' --address :9000 \
    --provisioner x --password-file $t/pw --provisioner-password-file $t/pw --deployment-type standalone >/dev/null 2>&1
    cp $t/f/certs/root_ca.crt /etc/step-ca/certs/root_ca.crt; cp $t/f/certs/intermediate_ca.crt /etc/step-ca/certs/intermediate_chain.crt
    cp $t/f/secrets/intermediate_ca_key /etc/step-ca/secrets/intermediate_ca_key; chown -R step:step /etc/step-ca' < "$W/key.pw"
  x bash "$sc" switch --from $S --to $P --from-down; r=$?; grep -q 'refused before unlock' "$W/last"; u=$?
  dk exec $P test ! -e /etc/step-ca/password.txt; f=$?; [ $r != 0 ] && [ $u = 0 ] && [ $f = 0 ]; c $? 0 "a foreign intermediate is refused before unlock"
  return $bad
}

echo "== as published"; suite "$SCRIPT"; n=$?
[ $n = 0 ] && echo "ok    as-published: every case as expected" || { echo "FAIL  as-published: $n case(s) not as expected"; exit 1; }
[ -n "${CA_DRILL_CASES_ONLY:-}" ] && { echo "cases only (CA_DRILL_CASES_ONLY): arms not run"; exit 0; }
arms=0
arm() {  # arm <name> <the case it must break> <old> <new> [<old> <new>...]   (CA_DRILL_ARMS="a b": only those)
  local name=$1 want=$2; shift 2; local a="$W/arm-$name.sh"
  [ -z "${CA_DRILL_ARMS:-}" ] || [[ " $CA_DRILL_ARMS " == *" $name "* ]] || return 0
  python3 - "$SCRIPT" "$a" "$@" <<'EOF' || { echo "FAIL  arm $name: its text is not in the script"; arms=$((arms+1)); return; }
import sys
s = open(sys.argv[1]).read(); pairs = sys.argv[3:]
for old, new in zip(pairs[::2], pairs[1::2]):
    if old not in s: sys.exit(1)
    s = s.replace(old, new)
open(sys.argv[2], "w").write(s)
EOF
  echo "== arm $name"; suite "$a" >"$W/arm.out"
  if grep -q "BAD  $want (" "$W/arm.out"; then echo "ok    $name: red on '$want'"
  else echo "FAIL  $name: '$want' did not go red"; grep BAD "$W/arm.out" | sed 's/^/  /'; arms=$((arms+1)); fi
}
arm no-exclude        "copy P -> S"  "--exclude=./password.txt --exclude=./provisioner-password.txt " ""
arm no-thaw           "P is not left stopped"  'timeout "$FT" cp -a "$D/db" "$t/s/db" 9>&-; thaw;' 'timeout "$FT" cp -a "$D/db" "$t/s/db" 9>&-;' 'trap "thaw; rm -rf $t" EXIT; trap "thaw; rm -rf $t; exit 1" HUP INT TERM' 'trap "rm -rf $t" EXIT' 'setsid sh -c' 'true sh -c'
arm no-error-thaw     "a failed database copy leaves P thawed"  'trap "thaw; rm -rf $t" EXIT; trap "thaw; rm -rf $t; exit 1" HUP INT TERM' 'trap "rm -rf $t" EXIT' 'setsid sh -c' 'true sh -c'
arm no-signal-trap    "a sender TERMed mid-freeze thaws P at once"  'trap "thaw; rm -rf $t" EXIT; trap "thaw; rm -rf $t; exit 1" HUP INT TERM' 'true'
arm no-watchdog       "a sender killed mid-freeze is thawed by the watchdog"  'setsid sh -c' 'true sh -c'
arm no-future-refusal "check refuses a stamp from the future"  '[ "$ages" -ge -300 ] || fail' 'true || fail'
arm no-run-refusal    "copy refused while S runs"  'systemctl is-active -q "$U" && { echo "step-ca is running here"; return 0; }' 'false && { echo; }'
arm no-password-refusal "copy refused while S holds a password file"  '[ ! -e "$D/password.txt" ] && [ ! -e "$D/provisioner-password.txt" ] || { echo "a password file is here"; return 0; }' 'true'
arm no-enabled-refusal "copy refused while S's unit is enabled"  'systemctl is-enabled -q "$U" 2>/dev/null && { echo "step-ca is enabled here"; return 0; }' 'false && { echo; }'
arm no-stale-refusal  "a wrong-way copy onto a newer CA is refused"  '[ "$FORCE" = 1 ] || [ "$inc" -ge "$mine" ] || bad' 'true || bad'
arm no-trailer        "receive refuses an altered file"  '(cd "$D.new" && sha256sum --quiet -c .ca-standby-sums) >/dev/null 2>&1 || bad' 'true || bad'
arm no-unlisted       "receive refuses a file the trailer does not list"  '[ "$n" = "$(wc -l < "$D.new/.ca-standby-sums")" ] || bad' 'true || bad'
arm no-recv-password  "receive refuses a password file"  'do [ ! -e "$D.new/$f" ] || bad' 'do true || bad'
arm no-recv-cajson    "receive refuses a stream with no ca.json"  '[ -s "$D.new/config/ca.json" ] || bad' 'true || bad'
arm no-recv-rootkey   "receive refuses the root key"  '[ ! -e "$D.new/secrets/root_ca_key" ] || bad' 'true || bad'
arm no-open-check     "check fails on a database that does not open"  'o=$(onn "$TO" "$OPENS")' 'o=opens'
arm no-b64            "ssh: copy through sshd, a dash login shell"  '"$SSH_USER@$1" "sudo -n bash -c \"\$(echo $b | base64 -d)\""' '"$SSH_USER@$1" "sudo -n bash -c $(printf %q "$2")"'
arm no-pw-precheck    "an empty password item stops the switch before the fence"  '[ "$n" -gt 0 ] || fail "the item' 'true || fail "the item'
arm no-fence-disable  "P fenced: stopped, disabled, no password, port closed"  'systemctl disable --now "$U" >/dev/null 2>&1 || true; rm -f "$D/password.txt"' 'systemctl stop "$U" >/dev/null 2>&1 || true; rm -f "$D/password.txt"' 'FENCED=$(printf '"'"'unit=stopped\nenabled=no\n' 'FENCED=$(printf '"'"'unit=stopped\nenabled=yes\n'
arm no-fence-refusal  "switch refused when the old primary does not answer"  '[ "$FROM_DOWN" = 1 ] || fail' 'true || fail'
arm no-step3-lock     "step 3 refused while another run holds the standby's lock"  'UNLOCK_START="set -uo pipefail; $LOCK"' 'UNLOCK_START="set -uo pipefail"'
arm no-fence-delete   "a returning host is fenced"  'systemctl disable --now "$U" >/dev/null 2>&1 || true; rm -f "$D/password.txt" "$D/provisioner-password.txt"' 'systemctl disable --now "$U" >/dev/null 2>&1 || true'
arm no-rollback       "a failed start rolls back"  "trap 'rollback \"\$TO\"' EXIT" "true"
arm no-rollback-stop  "a failed probe after a start rolls back: stopped and disabled"  'ROLLBACK="$FENCE"' 'ROLLBACK='"'"'rm -f '"'"'"$DIR"'"'"'/password.txt '"'"'"$DIR"'"'"'/provisioner-password.txt'"'"
arm no-disk-compare   "a foreign intermediate is refused before unlock"  '[ -n "$disk" ] && [ "$disk" = "$WANT" ] || {' 'true || {'
[ $arms = 0 ] && echo "all checks passed" || { echo "FAIL $arms arm(s) not red on their own case"; exit 1; }
