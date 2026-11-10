#!/usr/bin/env bash
# drill-segmentation.sh: every listening socket is declared, and none is bound wider than its declaration.
#
#   ./drill-segmentation.sh                      # local: two throwaway listeners and their declarations; every check must pass
#   ARM=widebind ./drill-segmentation.sh         # the loopback service bound to every address: exactly its bind check must FAIL
#   ARM=undeclared ./drill-segmentation.sh       # one more listener nobody declared: exactly the undeclared check must FAIL
#   REGISTRY=ports.tsv [CLUSTER_NETS="10.0.0.0/24 10.8.0.0/24"] ./drill-segmentation.sh machine
#                                                # this machine's real sockets, TCP and UDP, against a declaration file
#   Exit codes, the same in every neenv drill: 0 the run proved what it set out to (no ARM: every check passed;
#   an ARM: exactly that arm's checks failed); 1 it did not; 2 it could not run (a missing tool, a setup step).
#
# Needs bash, ss (iproute2 with -H) and python3. The registry is one line per socket:
#     <proto>/<port> <exposure> <name>      proto: tcp | udp      exposure: loopback | cluster | public
# loopback must bind 127.0.0.0/8 or ::1 only; cluster must not bind every address (0.0.0.0, ::, *), and with
# CLUSTER_NETS set must bind only addresses inside those networks; public may bind anything.
# What this cannot see: a container port published by the container runtime's own packet rules with no listening
# socket (Docker with userland-proxy off), and who can ROUTE to an address (see the pattern's README).
set -u
set -o pipefail

ARM=${ARM:-}
fails=0
failed=()
ok()   { printf 'ok    %s\n' "${*:2}"; }
fail() { printf 'FAIL  %s\n' "${*:2}"; fails=$((fails + 1)); failed+=("$1"); }

# "<proto>/<port> <address>" for every listening TCP and UDP socket. A scope (%lo, %wg0) is dropped from the address and
# kept as "@iface"; an IPv4-mapped IPv6 address is read as the IPv4 address it is. Exits 2 if ss fails or sees nothing.
sockets() {
  local raw
  raw=$(ss -ltunH 2>&1) || { echo "ss failed: $raw" >&2; exit 2; }
  [[ -n $raw ]] || { echo "ss reported no listening sockets at all: refusing to call that a pass" >&2; exit 2; }
  awk '{print $1, $5}' <<<"$raw" | while read -r proto local; do
    local port=${local##*:} addr=${local%:*}
    addr=${addr#[}; addr=${addr%]}
    local scope=''
    [[ $addr == *%* ]] && { scope="@${addr#*%}"; addr=${addr%%%*}; }
    addr=${addr%]}                       # ss writes a scoped IPv6 address as [fe80::1]%eno1: the bracket comes first
    addr=${addr#::ffff:}
    echo "$proto/$port $addr$scope"
  done | sort -u
}

in_nets() {   # $1 address, rest: CIDRs; python decides, so IPv6 and odd prefixes are right
  python3 -I -c 'import ipaddress,sys
a=ipaddress.ip_address(sys.argv[1]); sys.exit(0 if any(a in ipaddress.ip_network(n, strict=False) for n in sys.argv[2:]) else 1)' "$@"
}

judge() {   # $1 registry file, $2 keys to consider ('' = all)
  local reg=$1 only=$2 key exposure name addr binds
  declare -A decl
  while read -r key exposure name; do
    [[ -z $key || $key == \#* ]] && continue
    [[ $key == tcp/* || $key == udp/* ]] || { echo "registry line '$key $exposure $name': the first field is proto/port" >&2; exit 2; }
    decl[$key]="$exposure $name"
  done <"$reg"
  local seen; seen=$(sockets) || exit 2
  local undeclared=()
  while read -r key addr; do
    [[ -n $only && " $only " != *" $key "* ]] && continue
    [[ -n ${decl[$key]:-} ]] || undeclared+=("$key@$addr")
  done <<<"$seen"
  if (( ${#undeclared[@]} == 0 )); then ok undeclared "every listening socket is declared"
  else fail undeclared "listening and declared nowhere: ${undeclared[*]}"; fi
  for key in $(printf '%s\n' "${!decl[@]}" | sort -t/ -k2 -n); do
    [[ -n $only && " $only " != *" $key "* ]] && continue
    read -r exposure name <<<"${decl[$key]}"
    binds=$(awk -v k="$key" '$1 == k {print $2}' <<<"$seen" | paste -sd' ' -)
    [[ -z $binds ]] && { echo "      ($name, $key: declared, not listening now)"; continue; }
    local wide=() b plain
    for b in $binds; do
      plain=${b%@*}
      case $exposure in
        loopback) [[ $plain == 127.* || $plain == ::1 ]] || wide+=("$b") ;;
        cluster)  if [[ $plain == 0.0.0.0 || $plain == :: || $plain == '*' ]]; then wide+=("$b")
                  elif [[ -n ${CLUSTER_NETS:-} ]] && ! in_nets "$plain" 127.0.0.0/8 ::1/128 $CLUSTER_NETS; then wide+=("$b"); fi ;;
        public)   ;;
        *)        echo "unknown exposure '$exposure' for $key" >&2; exit 2 ;;
      esac
    done
    if (( ${#wide[@]} )); then fail "bind-$name" "$name ($key) is declared $exposure and listens on: ${wide[*]}"
    else ok "bind-$name" "$name ($key) is $exposure and listens on: $binds"; fi
  done
}

drill_local() {
  command -v ss >/dev/null && command -v python3 >/dev/null || { echo "ss and python3 are required" >&2; exit 2; }
  [[ -z $ARM || $ARM == widebind || $ARM == undeclared ]] || { echo "ARM must be empty, widebind or undeclared" >&2; exit 2; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/drill-segmentation.XXXXXX")
  pids=''
  trap 'for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "$d"' EXIT
  local base=$(( 20000 + RANDOM % 30000 ))
  local db=$base web=$((base + 1)) extra=$((base + 2))
  printf 'tcp/%s loopback database\ntcp/%s public web\n' "$db" "$web" >"$d/ports.tsv"
  start() { python3 -m http.server --bind "$1" "$2" >"$d/$2.log" 2>&1 & pids="$pids $!"; }
  start "$([[ $ARM == widebind ]] && echo 0.0.0.0 || echo 127.0.0.1)" "$db"
  start 0.0.0.0 "$web"
  local judged="tcp/$db tcp/$web"
  [[ $ARM == undeclared ]] && { start 127.0.0.1 "$extra"; judged="$judged tcp/$extra"; }
  # every listener must be OURS and up: a port another program already held would be a stranger's socket judged
  local i p up
  for i in $(seq 1 25); do
    up=0; for p in $pids; do kill -0 "$p" 2>/dev/null && up=$((up + 1)); done
    local listening=0 k; for k in $judged; do sockets | grep -q "^$k " && listening=$((listening + 1)); done
    (( up == $(wc -w <<<"$pids") && listening == $(wc -w <<<"$judged") )) && break; sleep 0.2
  done
  (( up == $(wc -w <<<"$pids") && listening == $(wc -w <<<"$judged") )) \
    || { echo "the throwaway listeners did not all start (a port may be taken): $judged"; cat "$d"/*.log; exit 2; }
  echo "listeners on $judged; declared: database tcp/$db loopback, web tcp/$web public"
  judge "$d/ports.tsv" "$judged"
}

drill_machine() {
  command -v ss >/dev/null && command -v python3 >/dev/null || { echo "ss and python3 are required" >&2; exit 2; }
  [[ -z $ARM ]] || { echo "machine has no arm" >&2; exit 2; }
  [[ -r ${REGISTRY:-} ]] || { echo "REGISTRY=<file> is required: one '<proto>/<port> <exposure> <name>' line per socket" >&2; exit 2; }
  judge "$REGISTRY" ''
}

case ${1:-local} in
  local)   drill_local ;;
  machine) drill_machine ;;
  *)       sed -n '2,18p' "$0"; exit 2 ;;
esac

case $ARM in
  widebind)
    if [[ "${failed[*]}" == "bind-database" ]]; then echo "ARM: exactly the database's bind check failed when it listened everywhere, as it must"; exit 0; fi
    echo "ARM: the checks that failed were '${failed[*]}', not 'bind-database'"; exit 1 ;;
  undeclared)
    if [[ "${failed[*]}" == "undeclared" ]]; then echo "ARM: exactly the undeclared check failed for the listener nobody declared, as it must"; exit 0; fi
    echo "ARM: the checks that failed were '${failed[*]}', not 'undeclared'"; exit 1 ;;
esac
(( fails == 0 )) || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
