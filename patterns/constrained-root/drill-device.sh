#!/bin/bash
# drill-device.sh — show on a real phone or laptop that a root limited to your names makes the browser refuse a
# certificate it signed for any other name. A THROWAWAY constrained root is made in a private temporary directory;
# no real key is used.
#
#   ./drill-device.sh check          builds the root and two leaves, proves them on this machine, removes everything
#   ./drill-device.sh serve ADDR     the same, then serves two pages on ADDR (an address of this machine on your
#                                    private network) for HOURS (default 2) and prints what to do on the device
#   ./drill-device.sh stop           stops the pages and deletes the directory (`serve` deletes the root key at once)
#   ARM=noconstraint                 the same root WITHOUT the constraint: `check` must then fail exactly the two
#                                    "foreign" refusals (openssl and curl), and nothing else
#   Exit codes, the same in every neenv drill: 0 the run proved what it set out to (no ARM: every check passed;
#   an ARM: exactly that arm's checks failed); 1 it did not; 2 it could not run (a missing tool, a setup step).
#   NC_FILE=<file>                   the constraint (default: name-constraints.txt beside this script)
# Needs: OpenSSL >= 3.0 (not LibreSSL), python3, curl; `serve` also Linux's ip, setsid and GNU timeout.
# The two pages:  control  https://ADDR:8444/  a private address the root permits: must OPEN
#   foreign  https://<ADDR with dashes>.sslip.io:8443/  a public name sslip.io answers with ADDR: must be REFUSED
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NC=$(grep -v '^#' "${NC_FILE:-$HERE/name-constraints.txt}" | tr -d '\n ')
HOURS=${HOURS:-2}
STATE=${XDG_RUNTIME_DIR:-$HOME}/.constrained-root-drill   # names the one work directory `stop` removes
W=$(cat "$STATE" 2>/dev/null || true)

stop() { if [ -n "$W" ] && [ -d "$W" ]; then [ -f "$W/pids" ] && kill $(cat "$W/pids") 2>/dev/null || true; rm -rf "$W"; echo "stopped; $W removed"; else echo "nothing to stop"; fi; rm -f "$STATE"; W=""; }

build() {   # $1 = the address the control page answers on
  local addr=$1 foreign="${1//./-}.sslip.io" bad=0
  W=$(mktemp -d); chmod 700 "$W"
  openssl ecparam -name prime256v1 -genkey -noout -out "$W/root.key" 2>/dev/null
  local ext="basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash"
  [ "${ARM:-}" = noconstraint ] || ext="$ext
nameConstraints=$NC"
  printf '[r]\n%s\n' "$ext" > "$W/root.ext"
  openssl req -x509 -new -key "$W/root.key" -subj "/O=Device Drill/CN=Device Drill Root (our names)" -days 2 \
    -config "$W/root.ext" -extensions r -out "$W/root.crt"
  for n in foreign control; do
    openssl ecparam -name prime256v1 -genkey -noout -out "$W/$n.key" 2>/dev/null
    # the control's CN is text: OpenSSL checks an IP-looking CN against the DNS constraint and would refuse it
    if [ $n = foreign ]; then cn=$foreign san="DNS:$foreign"; else cn="device drill control" san="IP:$addr"; fi
    openssl req -new -key "$W/$n.key" -subj "/O=Device Drill/CN=$cn" -out "$W/$n.csr"
    printf '[s]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\nauthorityKeyIdentifier=keyid\n' "$san" > "$W/$n.ext"
    openssl x509 -req -in "$W/$n.csr" -CA "$W/root.crt" -CAkey "$W/root.key" -set_serial 0x$(openssl rand -hex 16) \
      -days 2 -extfile "$W/$n.ext" -extensions s -out "$W/$n.crt" 2>/dev/null
  done
  # refused for the RIGHT reason only: the name constraint, not a missing file or a bad signature
  local v; v=$(openssl verify -no-CApath -no-CAstore -CAfile "$W/root.crt" -purpose sslserver "$W/foreign.crt" 2>&1 || true)
  if grep -q "permitted subtree violation" <<< "$v"; then echo "PASS openssl foreign want=refused(constraint) got=refused(constraint)"
  else echo "FAIL openssl foreign want=refused(constraint) got=$(tail -1 <<< "$v" | cut -c1-80)"; bad=1; fi
  if openssl verify -no-CApath -no-CAstore -CAfile "$W/root.crt" -purpose sslserver "$W/control.crt" >/dev/null 2>&1
  then echo "PASS openssl control want=ok got=ok"; else echo "FAIL openssl control want=ok got=refused"; bad=1; fi
  return $bad
}

serve_pages() {   # $1 addr, $2 port suffix offset (0 for the real ports)
  local addr=$1 cport=$((8444 + $2)) fport=$((8443 + $2)) page='<!doctype html><meta name=viewport content="width=device-width"><body style="font:20px system-ui;margin:2em">'
  cat > "$W/serve.py" <<'EOF'
import http.server, ssl, sys
port, crt, key, body = int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5].encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer((sys.argv[1], port), H)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain(crt, key); s.socket = c.wrap_socket(s.socket, server_side=True)
s.serve_forever()
EOF
  setsid timeout ${HOURS}h python3 -I "$W/serve.py" "$addr" $fport "$W/foreign.crt" "$W/foreign.key" \
    "$page<h1 style=color:firebrick>FAILED</h1><p>This browser accepted a certificate the limited root signed for a name outside its limit.</p>" >>"$W/log" 2>&1 & echo $! > "$W/pids"
  setsid timeout ${HOURS}h python3 -I "$W/serve.py" "$addr" $cport "$W/control.crt" "$W/control.key" \
    "$page<h1 style=color:green>Control: OK</h1><p>This device trusts the drill root. Now open the other link: it must be refused.</p>" >>"$W/log" 2>&1 & echo $! >> "$W/pids"
  sleep 2
}

wire() {   # the same proof over the wire, with curl holding the drill root alone
  local addr=$1 foreign="${1//./-}.sslip.io" cport=$((8444 + $2)) fport=$((8443 + $2)) bad=0
  if curl -sk --resolve "$foreign:$fport:$addr" "https://$foreign:$fport/" | grep -q FAILED; then echo "PASS curl foreign serving (insecure read)"; else echo "FAIL curl foreign not serving"; bad=1; fi
  # refused for the name only: curl (OpenSSL) says 'permitted subtree violation'; any other error FAILs
  local e; e=$(curl -sS -o /dev/null --cacert "$W/root.crt" --resolve "$foreign:$fport:$addr" "https://$foreign:$fport/" 2>&1 && echo OPENED || true)
  if grep -q 'permitted subtree violation' <<< "$e"; then echo "PASS curl foreign want=refused(constraint) got=refused(constraint)"
  else echo "FAIL curl foreign want=refused(constraint) got=${e:0:80}"; bad=1; fi
  if curl -s --cacert "$W/root.crt" "https://$addr:$cport/" >/dev/null 2>&1; then echo "PASS curl control want=ok got=ok"; else echo "FAIL curl control want=ok got=refused"; bad=1; fi
  return $bad
}

case "${1:-}" in
  check)
    # build checks OpenSSL and wire checks curl; both print PASS/FAIL lines, judged together below. A run that
    # printed no check at all could not run (exit 2).
    rc=0; B=$(mktemp); build 127.0.0.1 > "$B" || rc=1; cat "$B"
    if [ -n "$W" ] && [ -f "$W/root.crt" ]; then serve_pages 127.0.0.1 10000; wire 127.0.0.1 10000 >> "$B" || rc=1; sed -n '/^PASS curl\|^FAIL curl/p' "$B"; fi
    out=$(cat "$B"); rm -f "$B"
    kill $(cat "$W/pids" 2>/dev/null) 2>/dev/null || true; rm -rf "$W"   # its own directory; a running `serve` is left alone
    grep -q '^\(PASS\|FAIL\) ' <<< "$out" || { echo "== check could not run"; exit 2; }
    if [ -n "${ARM:-}" ]; then
      got=$(awk '/^FAIL/{print $2"-"$3}' <<< "$out" | sort | paste -sd' ')
      [ "$got" = "curl-foreign openssl-foreign" ] && { echo "== ARM: exactly the two foreign refusals failed, as they must"; exit 0; }
      echo "== ARM: expected to fail [curl-foreign openssl-foreign], failed [$got]"; exit 1
    fi
    [ $rc = 0 ] && echo "== check passed" || echo "== check FAILED"; exit $rc ;;
  serve)
    addr=${2:?usage: $0 serve ADDR}
    ip -4 -br addr 2>/dev/null | awk -v a="$addr" '{for(i=3;i<=NF;i++){split($i,x,"/"); if(x[1]==a) f=1}} END{exit !f}' \
      || { echo "refused: $addr is not an address of this machine" >&2; exit 2; }
    stop >/dev/null; build "$addr" || { rm -rf "$W"; exit 1; }; echo "$W" > "$STATE"
    rm -f "$W/root.key"   # the leaves are signed; nothing more will be, so the key goes now
    serve_pages "$addr" 0; wire "$addr" 0 || { stop >/dev/null; exit 1; }
    f="${addr//./-}.sslip.io"; r=$(getent ahostsv4 "$f" 2>/dev/null | awk 'NR==1{print $1}')
    [ "$r" = "$addr" ] || echo "WARNING: $f resolves to '${r:-nothing}' here, not $addr. A resolver with DNS-rebind protection (dnsmasq, OpenWrt, Pi-hole) drops public names that answer private addresses; the device would then fail on DNS, which is NOT the refusal."
    cat <<EOF
On the device:
  1. install $W/root.crt as a trusted root (copy it over; on iOS also turn on full trust for it);
  2. open https://$addr:8444/         — it must say "Control: OK" with no warning;
  3. open https://${addr//./-}.sslip.io:8443/  — the browser must refuse it with a CERTIFICATE error ("connection is
     not private", "certificate is not valid"). "Server not found" or a DNS error proves nothing: see the warning above;
  4. remove the drill root from the device, then run: $0 stop   (it deletes $W; the root key is already gone)
The pages stop by themselves after $HOURS h.
EOF
    ;;
  stop) stop ;;
  *) sed -n 2,14p "$0"; exit 2 ;;
esac
