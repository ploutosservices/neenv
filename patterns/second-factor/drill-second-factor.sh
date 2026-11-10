#!/usr/bin/env bash
# drill-second-factor.sh: an administrator's page opens only with BOTH factors: the password, and a certificate
# issued to one of the person's own machines.
#
#   ./drill-second-factor.sh                 # a throwaway person CA and an nginx admin door; every check must pass
#   ARM=nocert ./drill-second-factor.sh      # the door checks no certificate: exactly the 4 checks that need one must FAIL
#   ARM=nobinding ./drill-second-factor.sh   # any person's certificate with anyone's password: exactly the 1 binding check must FAIL
#   Exit codes, the same in every neenv drill: 0 the run proved what it set out to (no ARM: every check passed;
#   an ARM: exactly that arm's checks failed); 1 it did not; 2 it could not run (a missing tool, a setup step).
#
# Needs bash (4.4 or later), curl, OpenSSL 1.1.1 or later (not LibreSSL) and nginx. Runs as any user, on loopback. The password stands for the first factor
# (in production it is the identity provider's sign-in); the machine certificate is the second.
set -u
set -o pipefail

ARM=${ARM:-}
fails=0
failed=()
ok()   { printf 'ok    %s\n' "${*:2}"; }
fail() { printf 'FAIL  %s\n' "${*:2}"; fails=$((fails + 1)); failed+=("$1"); }

for t in curl openssl "${NGINX_BIN:-nginx}"; do command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 2; }; done
[[ -z $ARM || $ARM == nocert || $ARM == nobinding ]] || { echo "ARM must be empty, nocert or nobinding" >&2; exit 2; }
d=$(mktemp -d "${TMPDIR:-/tmp}/drill-second-factor.XXXXXX") || exit 2
[[ -n $d && -d $d ]] || exit 2
trap '[[ -n ${npid:-} ]] && kill "$npid" 2>/dev/null; [[ -s $d/nginx.pid ]] && kill "$(cat "$d/nginx.pid")" 2>/dev/null; rm -rf "$d"' EXIT
cd "$d" || exit 2

# throwaway passwords, made for this run (never typed into the script)
alice_pw=$(openssl rand -hex 12) bob_pw=$(openssl rand -hex 12)
# a person CA (its key stays here, on the CA's side); alice's and bob's laptops each hold a certificate from it, whose
# key was made on the laptop; a stranger's machine holds one from another CA
{
  for ca in person stranger; do
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=$ca CA" -keyout "$ca-ca.key" -out "$ca-ca.crt"
  done
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=127.0.0.1" \
    -addext "subjectAltName=IP:127.0.0.1" -keyout door.key -out door.crt
  for who in "alice-laptop:person" "bob-laptop:person" "stranger-pc:stranger"; do
    n=${who%%:*}; ca=${who##*:}
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$n" -keyout "$n.key" -out "$n.csr"
    openssl x509 -req -in "$n.csr" -CA "$ca-ca.crt" -CAkey "$ca-ca.key" -CAcreateserial -days 1 -out "$n.crt"
  done
  printf 'alice:%s\nbob:%s\n' "$(openssl passwd -apr1 "$alice_pw")" "$(openssl passwd -apr1 "$bob_pw")" >htpasswd
} >setup.log 2>&1 || { cat setup.log; exit 2; }

port=$(( 20000 + RANDOM % 30000 ))
cert_rule='            if ($ssl_client_verify != SUCCESS) { return 403; }   # the second factor: a machine the person CA vouches for'
bind_rule='            if ($cert_mismatch) { return 403; }                  # ...and it is THIS person'"'"'s machine'
[[ $ARM == nocert ]] && { cert_rule='            # (arm: no certificate checked)'; bind_rule='            # (arm: no binding)'; }
[[ $ARM == nobinding ]] && bind_rule='            # (arm: no binding)'
mkdir -p www/admin && echo "admin page" >www/admin/index.html
cat >nginx.conf <<EOF
worker_processes 1;
pid $d/nginx.pid;
error_log $d/error.log;
events { worker_connections 64; }
http {
    access_log off;
    # the person a certificate names (CN=<person>-<machine>), and whether it differs from the user being signed in as.
    # \$remote_user is read from the request before the password is checked; an empty one is left to auth_basic (401).
    map \$ssl_client_s_dn \$cert_user { "~CN=(?<p>[a-z]+)-" \$p; default ""; }
    map "\$cert_user:\$remote_user" \$cert_mismatch { "~^([a-z]*):\\1\$" 0; "~^[a-z]*:\$" 0; default 1; }
    client_body_temp_path $d/tb; proxy_temp_path $d/tp; fastcgi_temp_path $d/tf; uwsgi_temp_path $d/tu; scgi_temp_path $d/ts;
    server {
        listen 127.0.0.1:$port ssl;
        ssl_certificate $d/door.crt;
        ssl_certificate_key $d/door.key;
        ssl_client_certificate $d/person-ca.crt;
        ssl_verify_client optional_no_ca;   # a certificate that fails verification reaches the rule below (403), not a 400
        root $d/www;
        location /admin/ {
            # Both ifs run in nginx's rewrite phase, BEFORE auth_basic's access phase: a missing or foreign
            # certificate is 403 without the password ever being asked for, and a valid one falls through to it.
$cert_rule
$bind_rule
            auth_basic "admin";                               # the first factor
            auth_basic_user_file $d/htpasswd;
        }
    }
}
EOF
nginx=${NGINX_BIN:-nginx}
"$nginx" -t -q -p "$d" -c "$d/nginx.conf" -e "$d/error.log" 2>/dev/null || { cat error.log; exit 2; }
"$nginx" -p "$d" -c "$d/nginx.conf" -e "$d/error.log" -g 'daemon off;' </dev/null >/dev/null 2>&1 &
npid=$!
for i in $(seq 1 25); do [[ -s nginx.pid ]] && curl -sk -o /dev/null "https://127.0.0.1:$port/" && break; sleep 0.2; done
[[ -s nginx.pid ]] && curl -sk -o /dev/null "https://127.0.0.1:$port/" || { echo "nginx did not start on $port"; cat error.log; exit 2; }
echo "admin door on 127.0.0.1:$port$([[ $ARM == nocert ]] && echo ', certificate NOT checked')"

try() {   # $1 id, $2 expected code, $3 what, then curl arguments
  local id=$1 want=$2 what=$3; shift 3
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert door.crt "$@" "https://127.0.0.1:$port/admin/")
  if [[ $code == "$want" ]]; then ok "$id" "$what -> $code"; else fail "$id" "$what -> $code, not $want"; fi
}
try both      200 "alice's password and alice's laptop"            -u "alice:$alice_pw" --cert alice-laptop.crt --key alice-laptop.key
try password  403 "alice's password alone, no certificate"         -u "alice:$alice_pw"
try stranger  403 "alice's password and another CA's certificate"  -u "alice:$alice_pw" --cert stranger-pc.crt --key stranger-pc.key
try bobcert   403 "alice's password and bob's laptop"              -u "alice:$alice_pw" --cert bob-laptop.crt --key bob-laptop.key
try neither   403 "neither factor"
try wrongpass 401 "a wrong password and alice's laptop"            -u "alice:not-$alice_pw" --cert alice-laptop.crt --key alice-laptop.key
try certonly  401 "alice's laptop alone, no password"              --cert alice-laptop.crt --key alice-laptop.key

case $ARM in
  nocert)
    if [[ "${failed[*]-}" == "password stranger bobcert neither" ]]; then echo "ARM: exactly the 4 checks that need the second factor failed without it, as they must"; exit 0; fi
    echo "ARM: the checks that failed were '${failed[*]-}', not 'password stranger bobcert neither'"; exit 1 ;;
  nobinding)
    if [[ "${failed[*]-}" == "bobcert" ]]; then echo "ARM: exactly the binding check failed when any person's certificate was enough, as it must"; exit 0; fi
    echo "ARM: the checks that failed were '${failed[*]-}', not 'bobcert'"; exit 1 ;;
esac
(( fails == 0 )) || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
