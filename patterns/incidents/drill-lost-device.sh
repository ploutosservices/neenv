#!/usr/bin/env bash
# drill-lost-device.sh: a lost laptop's certificate stops opening the door the moment it is removed, and not before.
#
#   ./drill-lost-device.sh                  # two people's laptops admitted; one is reported lost and removed; every check must pass
#   ARM=noreload ./drill-lost-device.sh     # the name is removed from the list but the door is not told: exactly the
#                                           # "lost laptop refused" check must FAIL (a removal nobody applied protects nothing)
#   Exit codes, the same in every neenv drill: 0 the run proved what it set out to (no ARM: every check passed;
#   an ARM: exactly that arm's checks failed); 1 it did not; 2 it could not run (a missing tool, a setup step).
#
# Needs bash, curl, OpenSSL 1.1.1 or later and nginx. Runs as any user, on loopback.
set -u
set -o pipefail
ARM=${ARM:-}
fails=0
failed=()
ok()   { printf 'ok    %s\n' "${*:2}"; }
fail() { printf 'FAIL  %s\n' "${*:2}"; fails=$((fails + 1)); failed+=("$1"); }
[[ -n ${NGINX_BIN:-} ]] || { NGINX_BIN=$(command -v nginx || echo /usr/sbin/nginx); }
for t in curl openssl "$NGINX_BIN"; do command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 2; }; done
[[ -z $ARM || $ARM == noreload ]] || { echo "ARM must be empty or noreload" >&2; exit 2; }
d=$(mktemp -d "${TMPDIR:-/tmp}/drill-lost-device.XXXXXX") || exit 2
[[ -n $d && -d $d ]] || exit 2
trap '[[ -n ${npid:-} ]] && kill "$npid" 2>/dev/null; rm -rf "$d"' EXIT
cd "$d" || exit 2
setup() { "$@" >>setup.log 2>&1 || { echo "setup failed: $*"; cat setup.log; exit 2; }; }
setup openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=person CA" -keyout ca.key -out ca.crt
setup openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=foreign CA" -keyout foreign.key -out foreign.crt
setup openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" -keyout door.key -out door.crt
for m in alice-laptop:ca bob-laptop:ca fake-alice:foreign; do
  n=${m%%:*}; issuer=${m##*:}; cn=$n; [[ $n == fake-alice ]] && cn=alice-laptop
  setup openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$cn" -keyout "$n.key" -out "$n.csr"
  setup openssl x509 -req -in "$n.csr" -CA "$issuer.crt" -CAkey "$issuer.key" -CAcreateserial -days 1 -out "$n.crt"
done
# the door's list of enrolled machines: the one place a removal is recorded
printf 'CN=alice-laptop 1;\nCN=bob-laptop 1;\n' >machines.map
port=$(( 20000 + RANDOM % 30000 ))
mkdir -p www && echo "inside" >www/index.html
cat >nginx.conf <<NGINX
worker_processes 1;
pid $d/nginx.pid;
error_log $d/error.log;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path $d/tb; proxy_temp_path $d/tp; fastcgi_temp_path $d/tf; uwsgi_temp_path $d/tu; scgi_temp_path $d/ts;
    map \$ssl_client_s_dn \$enrolled { default 0; include $d/machines.map; }
    server {
        listen 127.0.0.1:$port ssl;
        ssl_certificate $d/door.crt;
        ssl_certificate_key $d/door.key;
        ssl_client_certificate $d/ca.crt;
        ssl_verify_client optional_no_ca;
        root $d/www;
        location / {
            if (\$ssl_client_verify != SUCCESS) { return 403; }
            if (\$enrolled = 0) { return 403; }
        }
    }
}
NGINX
nginx=$NGINX_BIN
"$nginx" -t -q -p "$d" -c "$d/nginx.conf" -e "$d/error.log" 2>/dev/null || { cat error.log; exit 2; }
"$nginx" -p "$d" -c "$d/nginx.conf" -e "$d/error.log" -g 'daemon off;' </dev/null >/dev/null 2>&1 &
npid=$!
for i in $(seq 1 25); do curl -sk -o /dev/null "https://127.0.0.1:$port/" && break; sleep 0.2; done
sleep 0.5   # a port someone else held: our nginx would have exited by now
kill -0 "$npid" 2>/dev/null && curl -sk -o /dev/null "https://127.0.0.1:$port/" || { echo "nginx did not start on $port"; cat error.log; exit 2; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert door.crt --cert "$1.crt" --key "$1.key" "https://127.0.0.1:$port/"; }
try() { local id=$1 who=$2 want=$3 what=$4 c; c=$(code "$who"); [[ $c == "$want" ]] && ok "$id" "$what -> $c" || fail "$id" "$what -> $c, not $want"; }
echo "door on 127.0.0.1:$port"
try before   bob-laptop   200 "bob's laptop before anything is lost"
try foreign  fake-alice   403 "a foreign CA's certificate named alice-laptop"
# bob reports his laptop lost: its name leaves the list, and the door is told (reload)
sed -i '/CN=bob-laptop/d' machines.map
[[ $ARM == noreload ]] || kill -HUP "$npid"
sleep 1
try lost     bob-laptop   403 "bob's lost laptop after its removal"
try other    alice-laptop 200 "alice's laptop, untouched by bob's loss"
if [[ $ARM == noreload ]]; then
  if [[ "${failed[*]-}" == "lost" ]]; then echo "ARM: exactly the lost laptop's refusal failed when the door was not told, as it must"; exit 0; fi
  echo "ARM: the checks that failed were '${failed[*]-}', not 'lost'"; exit 1
fi
(( fails == 0 )) || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
