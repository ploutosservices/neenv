#!/usr/bin/env bash
# drill-names.sh: a private name answers only a private source; a public name may carry a private address.
#
#   ./drill-names.sh                       # local: a throwaway nginx with the fence; every check must pass
#   ARM=nofence ./drill-names.sh           # the same nginx without the fence: the refusal checks must FAIL
#   ./drill-names.sh dns NAME ADDRESS [RESOLVER ...]
#                                          # public resolvers answer NAME with the private ADDRESS
#
# local needs bash, curl and an nginx built with the realip module (Debian's, Homebrew's and the
# official images are). NGINX_BIN=/path/to/nginx picks another binary
# (nginx itself reads a variable named NGINX, so the drill does not use that name). dns needs dig.
#
# The local drill simulates the source address. nginx trusts a header, X-Drill-Source, from 127.0.0.1
# alone and takes it as the caller's address (the realip module), so one machine can play a caller
# on the private network (10.0.0.5) and a caller on the internet (192.0.2.50). The fence that is
# tested is the one the README shows, as an included file. Never put the header trust on a real proxy.
set -u
set -o pipefail

PUBLIC_SRC=192.0.2.50      # documentation range: stands for any internet address
PRIVATE_SRC=10.0.0.5       # a device on the private network
ARM=${ARM:-}
fails=0

ok()   { printf 'ok    %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }

is_private() {   # RFC 1918, loopback and the shared range VPN meshes use (100.64.0.0/10)
  local a b
  IFS=. read -r a b _ _ <<<"$1"
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  (( a == 10 || a == 127 )) && return 0
  (( a == 172 && b >= 16 && b <= 31 )) && return 0
  (( a == 192 && b == 168 )) && return 0
  (( a == 100 && b >= 64 && b <= 127 )) && return 0
  return 1
}

drill_dns() {
  local name=${1:?usage: drill-names.sh dns NAME ADDRESS [RESOLVER ...]} want=${2:?ADDRESS missing}
  shift 2
  local resolvers=("$@")
  (( ${#resolvers[@]} )) || resolvers=(1.1.1.1 9.9.9.9)
  command -v dig >/dev/null || { echo "dig is required" >&2; exit 2; }
  if is_private "$want"; then ok "$want is a private address"
  else fail "$want is not a private address; this drill is for a public name carrying a private one"; fi
  local r got
  for r in "${resolvers[@]}"; do
    # +tries/+time: a resolver that does not answer is a FAIL, never an empty pass
    if ! got=$(dig +short +tries=2 +time=3 A "$name" @"$r" 2>&1); then
      fail "resolver $r did not answer: $got"; continue
    fi
    got=$(grep -E '^[0-9.]+$' <<<"$got" | sort -u | paste -sd' ' -)
    if [[ " $got " == *" $want "* ]]; then ok "$r answers $name with $want"
    else fail "$r answers $name with '${got:-nothing}', not $want"; fi
  done
}

write_conf() {   # $1 = directory, $2 = port, $3 = "fence" or "nofence"
  local d=$1 port=$2 fence=''
  # the fence, one file, as the README shows it; each private server block includes it
  cat >"$d/private-fence.conf" <<'FENCE'
# a private name answers a private source only
allow 10.0.0.0/8;
allow 172.16.0.0/12;
allow 192.168.0.0/16;
allow 127.0.0.0/8;
deny all;
FENCE
  [[ $3 == fence ]] && fence="
        include $d/private-fence.conf;"
  cat >"$d/nginx.conf" <<EOF
worker_processes 1;
pid $d/nginx.pid;
error_log $d/error.log;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path $d/tmp-body;
    proxy_temp_path $d/tmp-proxy;
    fastcgi_temp_path $d/tmp-fastcgi;
    uwsgi_temp_path $d/tmp-uwsgi;
    scgi_temp_path $d/tmp-scgi;

    # SIMULATION ONLY: the caller's address comes from a header sent by this machine
    set_real_ip_from 127.0.0.1;
    real_ip_header X-Drill-Source;

    server {                                   # an undeclared name reaches nothing
        listen 127.0.0.1:$port default_server;
        server_name _;
        return 404;
    }
    server {                                   # a public site: anyone
        listen 127.0.0.1:$port;
        server_name www.example.org;
        root $d/www/public;   # a page, not "return": return runs before allow/deny
    }
    server {                                   # private by its suffix
        listen 127.0.0.1:$port;
        server_name notes.home.arpa;$fence
        root $d/www/notes;   # a page, not "return": return runs before allow/deny
    }
    server {                                   # a public name on a private address: internal_only
        listen 127.0.0.1:$port;
        server_name tools.example.org;$fence
        root $d/www/tools;   # a page, not "return": return runs before allow/deny
    }
}
EOF
}

drill_local() {
  local nginx=${NGINX_BIN:-nginx}
  command -v "$nginx" >/dev/null || { echo "nginx is required (or NGINX_BIN=/path/to/nginx)" >&2; exit 2; }
  command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }
  local port shape=fence   # d stays global: the EXIT trap reads it after this function returns
  [[ $ARM == nofence ]] && shape=nofence
  [[ -z $ARM || $ARM == nofence ]] || { echo "ARM must be empty or nofence" >&2; exit 2; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/drill-names.XXXXXX")
  trap '[[ -s $d/nginx.pid ]] && kill "$(cat "$d/nginx.pid")" 2>/dev/null; rm -rf "$d"' EXIT
  port=$(( 20000 + RANDOM % 20000 ))
  write_conf "$d" "$port" "$shape"
  local w; for w in public notes tools; do mkdir -p "$d/www/$w"; echo "$w" >"$d/www/$w/index.html"; done
  "$nginx" -t -q -p "$d" -c "$d/nginx.conf" -e "$d/error.log" || { cat "$d/error.log"; exit 2; }
  # in the foreground of a background job, with no terminal held, so the drill owns its lifetime
  "$nginx" -p "$d" -c "$d/nginx.conf" -e "$d/error.log" -g 'daemon off;' </dev/null >/dev/null 2>&1 &
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do [[ -s $d/nginx.pid ]] && break; sleep 0.2; done
  [[ -s $d/nginx.pid ]] || { echo "nginx did not start:"; cat "$d/error.log"; exit 2; }
  echo "nginx on 127.0.0.1:$port, $shape"

  # expect NAME SOURCE CODE WHY: the exact status, or FAIL (a dead server is 000 and fails)
  expect() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
             -H "Host: $1" -H "X-Drill-Source: $2" "http://127.0.0.1:$port/")
    if [[ $code == "$3" ]]; then ok "$1 from $2 -> $code ($4)"
    else fail "$1 from $2 -> $code, not $3 ($4)"; fi
  }
  expect www.example.org   "$PUBLIC_SRC"  200 "a public site serves the internet"
  expect notes.home.arpa   "$PRIVATE_SRC" 200 "a private name serves the private network"
  expect tools.example.org "$PRIVATE_SRC" 200 "a public name on a private address serves the private network"
  expect notes.home.arpa   "$PUBLIC_SRC"  403 "a private name refuses the internet"
  expect tools.example.org "$PUBLIC_SRC"  403 "a public name on a private address refuses the internet"
  expect undeclared.example.org "$PRIVATE_SRC" 404 "an undeclared name reaches nothing"
}

case ${1:-local} in
  local) drill_local ;;
  dns)   shift; drill_dns "$@" ;;
  *)     sed -n '2,8p' "$0"; exit 2 ;;
esac

if [[ $ARM == nofence ]]; then
  if (( fails )); then echo "ARM: $fails check(s) failed without the fence, as they must"; exit 1; fi
  echo "ARM: every check passed without the fence: the drill cannot tell a refusal from a served page"; exit 3
fi
(( fails == 0 )) || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
