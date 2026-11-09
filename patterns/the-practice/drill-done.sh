#!/bin/bash
# drill-done.sh — "work is done when its consumer says so", as a script. The consumer calls the door it was promised
# with the certificate it really holds; the same request with no certificate, and with another consumer's valid
# certificate, must both be refused.
#
#   ./drill-done.sh URL CERT KEY [OTHER_CERT OTHER_KEY]
#        URL: the door; CERT, KEY: the consumer's client certificate and key; OTHER_*: a valid certificate from the
#        same root that belongs to someone this door must NOT admit (another tenant, another application)
#   ./drill-done.sh selftest
#        builds a THROWAWAY root, two consumer certificates and three local doors, shows one pass and three failures,
#        and removes everything
#   CA=<file>       the root the door's own certificate chains to (default: the system's)
#   METHOD=<verb>   the request method (default GET)
# Refused: 401, 403; a 400 that the proxy sends for a missing or bad client certificate; a TLS handshake the door
#          refuses (curl exit 35, 55 or 56: under TLS 1.3 a refused client certificate surfaces on the first send).
# Failed:  404, a promised door that does not exist; no connection at all (curl exit 6, 7, 28): the door was not reached.
# Reach:   any other answer (200, 201, 204, 400, 405, 422, ...): the door exists and let the caller in.
# Needs: curl; selftest also OpenSSL and python3.
set -euo pipefail
ME=$(realpath "$0")

# classify <curl args...>: prints one of reach|refused|missing|unreached, then the detail
classify() {
  local body code x
  body=$(mktemp)
  code=$(curl -s -o "$body" -w '%{http_code}' --max-time 20 -X "${METHOD:-GET}" ${CA:+--cacert "$CA"} "$@") && x=0 || x=$?
  # A status code, when there is one, is the answer; curl's exit code speaks only when no answer came.
  if [ "$code" = 000 ] && [[ "$x" =~ ^(35|55|56)$ ]]; then echo "refused the TLS handshake refused the certificate"
  elif [ "$code" = 000 ]; then echo "unreached no answer (curl exit $x)"
  elif [ "$code" = 401 ] || [ "$code" = 403 ]; then echo "refused $code"
  elif [ "$code" = 400 ] && grep -qi 'SSL certificate' "$body"; then echo "refused 400 from the proxy: no or bad client certificate"
  elif [ "$code" = 404 ]; then echo "missing 404"
  else echo "reach $code"; fi
  rm -f "$body"
}

drill() {   # URL CERT KEY [OTHER_CERT OTHER_KEY]
  local url=$1 fail=0 r d
  read -r r d <<<"$(classify --cert "$2" --key "$3" "$url")"
  case $r in
    reach)   echo "ok    with the consumer's certificate: $d (reach)" ;;
    missing) echo "FAIL  with the consumer's certificate: 404, a promised door that does not exist"; fail=1 ;;
    *)       echo "FAIL  with the consumer's certificate: $d"; fail=1 ;;
  esac
  read -r r d <<<"$(classify "$url")"
  case $r in
    refused)   echo "ok    with no certificate: $d (refused)" ;;
    unreached) echo "FAIL  with no certificate: $d, so nothing was proved"; fail=1 ;;
    *)         echo "FAIL  with no certificate: $d, so the door does not tell the consumer from a stranger"; fail=1 ;;
  esac
  if [ -n "${4:-}" ]; then
    read -r r d <<<"$(classify --cert "$4" --key "$5" "$url")"
    case $r in
      refused)   echo "ok    with another consumer's valid certificate: $d (refused)" ;;
      unreached) echo "FAIL  with another consumer's certificate: $d, so nothing was proved"; fail=1 ;;
      *)         echo "FAIL  with another consumer's valid certificate: $d, so any certificate from the root gets in"; fail=1 ;;
    esac
  fi
  [ "$fail" = 0 ] && echo "DONE  the consumer reaches the door, and the door refuses everyone else"
  return "$fail"
}

selftest() {
  local w port a b c d
  w=$(mktemp -d); chmod 700 "$w"; trap 'kill $(cat "$w"/pid* 2>/dev/null) 2>/dev/null; rm -rf "$w"' EXIT
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$w/ca.key" -out "$w/ca.pem" \
    -days 1 -subj /CN=throwaway-root 2>/dev/null
  for n in door consumer stranger; do
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$w/$n.key" -out "$w/$n.csr" \
      -subj "/CN=$n" 2>/dev/null
    printf 'subjectAltName=DNS:localhost\n' > "$w/$n.ext"
    openssl x509 -req -in "$w/$n.csr" -CA "$w/ca.pem" -CAkey "$w/ca.key" -CAcreateserial -out "$w/$n.pem" -days 1 \
      -extfile "$w/$n.ext" 2>/dev/null
  done
  # Three doors: "consumer" admits only the consumer; "anyone" admits any certificate from the root; "open" asks for none.
  cat > "$w/door.py" <<'EOF'
import http.server, ssl, sys
port, mode, d = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        cn = dict(x[0] for x in (self.connection.getpeercert() or {}).get("subject", ()))
        if mode == "consumer" and cn.get("commonName") != "consumer": code = 403
        else: code = 200 if self.path == "/door" else 404
        self.send_response(code); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", port), H)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain(d + "/door.pem", d + "/door.key")
if mode != "open":
    c.verify_mode = ssl.CERT_REQUIRED; c.load_verify_locations(d + "/ca.pem")
s.socket = c.wrap_socket(s.socket, server_side=True)
print("ready", flush=True); s.serve_forever()
EOF
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  local i=0
  for mode in consumer anyone open; do
    python3 "$w/door.py" $((port+i)) $mode "$w" > "$w/ready$i" & echo $! > "$w/pid$i"
    until grep -q ready "$w/ready$i" 2>/dev/null; do sleep 0.1; done
    i=$((i+1))
  done
  export CA="$w/ca.pem"
  t() { echo "-- $1"; shift; drill "$@" && return 0 || return 1; }
  t "the promised door, which admits only this consumer: must pass" "https://localhost:$port/door" \
    "$w/consumer.pem" "$w/consumer.key" "$w/stranger.pem" "$w/stranger.key" && a=0 || a=1
  t "a promised door that does not exist: must fail" "https://localhost:$port/missing" \
    "$w/consumer.pem" "$w/consumer.key" && b=0 || b=1
  t "a door that admits any certificate from the root: must fail" "https://localhost:$((port+1))/door" \
    "$w/consumer.pem" "$w/consumer.key" "$w/stranger.pem" "$w/stranger.key" && c=0 || c=1
  t "a door that asks for no certificate: must fail" "https://localhost:$((port+2))/door" \
    "$w/consumer.pem" "$w/consumer.key" && d=0 || d=1
  if [ "$a$b$c$d" = 0111 ]; then echo "SELFTEST passed: one pass, three failures"; exit 0; fi
  echo "SELFTEST FAILED: expected 0111, got $a$b$c$d"; exit 1
}

case "${1:-}" in
  selftest) selftest ;;
  *) [ $# -eq 3 ] || [ $# -eq 5 ] || { sed -n '2,20p' "$ME"; exit 2; }
     drill "$@" && exit 0 || exit 1 ;;
esac
