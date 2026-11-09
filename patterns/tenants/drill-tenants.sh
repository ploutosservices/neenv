#!/bin/bash
# drill-tenants.sh — the tenant fence at the edge, on this machine, with no credential and nothing left behind.
#
# It renders a real nginx configuration from a tenant declaration, runs it on loopback in front of a tiny backend
# that answers with every tenant header it received, and checks:
#   1. a declared name reaches the backend with its own tenant key;
#   2. a caller that sends X-Tenant itself (two copies: 'X-Tenant: family' and 'x-tenant: family') changes nothing;
#   3. a caller that sends X_Tenant (which CGI and PHP read as the same header) changes nothing;
#   4. a second tenant's name carries the second tenant's key;
#   5. a name nobody declared is refused at the TLS handshake and reaches no backend;
#   6. the same name over plain http gets a 404 and reaches no backend;
#   7. the renderer refuses a declaration that puts one name under two tenants.
#
#   ./drill-tenants.sh                 run the checks; exit 0 only when all seven pass
#   ARM=noheader ./drill-tenants.sh    the edge does not set the header        -> checks 1-4 must FAIL
#   ARM=underscores ./drill-tenants.sh nginx passes headers with underscores   -> check 3 must FAIL
#   ARM=invalidheaders ./drill-tenants.sh  nginx passes header names it calls invalid -> check 3 must FAIL
#   ARM=nodefault ./drill-tenants.sh   no default server refusing other names  -> checks 5-6 must FAIL
#   ARM=nocheck ./drill-tenants.sh     the renderer allows a name twice        -> check 7 must FAIL
#   In an ARM run the exit is 0 only when exactly those checks failed, which proves each check can fail.
#
# Needs: bash, nginx 1.19.4 or later (ssl_reject_handshake), python3, curl, openssl. No root: everything listens on
# 127.0.0.1 on free high ports, in a private temporary directory deleted on exit. NGINX_BIN=/path/to/nginx if not on PATH.
set -uo pipefail
ARM=${ARM:-}
case "$ARM" in ''|noheader|underscores|invalidheaders|nodefault|nocheck) ;; *) sed -n '2,22p' "$0"; exit 2;; esac

NGINX_BIN=${NGINX_BIN:-$(PATH="$PATH:/usr/sbin:/sbin" command -v nginx)}   # Debian keeps nginx in sbin
for t in python3 curl openssl; do command -v "$t" >/dev/null || { echo "needs $t"; exit 2; }; done
[ -n "$NGINX_BIN" ] && [ -x "$NGINX_BIN" ] || { echo "needs nginx (set NGINX_BIN=/path/to/nginx)"; exit 2; }

T=$(mktemp -d); chmod 700 "$T"
nginx_pid=; back_pid=
cleanup() { [ -n "$nginx_pid" ] && kill "$nginx_pid" 2>/dev/null; [ -n "$back_pid" ] && kill "$back_pid" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

# --- the declaration: one owner of "which tenant is this name" -------------------------------------------------
cat > "$T/tenants.yaml" <<'EOF'
tenants:
  acme:
    names:
      - acme.example.test
  family:
    names:
      - family.example.test
      - family.dev.example.test
EOF

# --- the renderer: declaration -> nginx. A name under two tenants is refused; nothing else invents a tenant -----
cat > "$T/render.py" <<'EOF'
import re, sys
decl, conf, http, https, back, arm = sys.argv[1], sys.argv[2], *sys.argv[3:6], sys.argv[6]
tenants, cur, inlist = {}, None, False
for n, line in enumerate(open(decl), 1):
    if not line.strip() or line.lstrip().startswith("#") or line.rstrip() == "tenants:":
        continue
    m = re.fullmatch(r"  ([a-z][a-z0-9-]*):\n?", line)
    if m:
        cur, inlist = m.group(1), False; tenants[cur] = []; continue
    if cur and re.fullmatch(r"    names:\n?", line):
        inlist = True; continue
    m = re.fullmatch(r"      - ([a-z0-9.-]+)\n?", line)
    if m and inlist:
        tenants[cur].append(m.group(1)); continue
    sys.exit(f"{decl}:{n}: not understood: {line.rstrip()}")
owner = {}
for key, names in tenants.items():
    for name in names:
        if name in owner and arm != "nocheck":
            sys.exit(f"REFUSED: {name} is declared under {owner[name]} and {key}; a name belongs to one tenant")
        owner[name] = key
T = conf.rsplit("/", 1)[0]
out = [f"""worker_processes 1;
pid {T}/nginx.pid;
events {{ worker_connections 64; }}
http {{
    access_log off;
    client_body_temp_path {T}/tmp-body; proxy_temp_path {T}/tmp-proxy; fastcgi_temp_path {T}/tmp-fcgi;
    uwsgi_temp_path {T}/tmp-uwsgi; scgi_temp_path {T}/tmp-scgi;
    ssl_certificate {T}/edge.crt; ssl_certificate_key {T}/edge.key;
"""]
if arm == "underscores":
    out.append("    underscores_in_headers on;\n")
if arm == "invalidheaders":
    out.append("    ignore_invalid_headers off;\n")
if arm != "nodefault":
    out.append(f"""    # a name nobody declared: refused, never routed to whichever block sorts first
    server {{ listen 127.0.0.1:{http} default_server; server_name _; return 404; }}
    server {{ listen 127.0.0.1:{https} ssl default_server; server_name _; ssl_reject_handshake on; }}
""")
for name, key in owner.items():
    header = "" if arm == "noheader" else f'proxy_set_header X-Tenant "{key}";   # replaces any copy the caller sent'
    out.append(f"""    server {{
        listen 127.0.0.1:{http}; listen 127.0.0.1:{https} ssl; server_name {name};
        location / {{
            proxy_pass http://127.0.0.1:{back};
            {header}
        }}
    }}
""")
out.append("}\n")
open(conf, "w").write("".join(out))
EOF

# --- the backend: answers with every tenant header it got, in any spelling; counts its requests -----------------
cat > "$T/backend.py" <<'EOF'
import http.server, sys
hits = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(hits, "a").write("x")
        got = [v for k, v in self.headers.items() if k.lower().replace("_", "-") == "x-tenant"]
        body = ("X-Tenant=" + (",".join(got) if got else "(none)")).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF

read -r HTTP HTTPS BACK <<<"$(python3 -I -c '
import socket; s=[socket.socket() for _ in range(3)]
[x.bind(("127.0.0.1",0)) for x in s]; print(*[x.getsockname()[1] for x in s])')"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=edge drill" \
  -addext "subjectAltName=DNS:acme.example.test,DNS:family.example.test,DNS:family.dev.example.test" \
  -keyout "$T/edge.key" -out "$T/edge.crt" >/dev/null 2>&1 || { echo "openssl could not make the drill certificate"; exit 2; }

python3 -I "$T/render.py" "$T/tenants.yaml" "$T/nginx.conf" "$HTTP" "$HTTPS" "$BACK" "$ARM" || exit 2
: > "$T/hits"
python3 -I "$T/backend.py" "$BACK" "$T/hits" & back_pid=$!
"$NGINX_BIN" -t -q -p "$T" -e "$T/error.log" -c "$T/nginx.conf" 2>"$T/t.err" || { echo "nginx -t failed:"; cat "$T/t.err"; exit 2; }
"$NGINX_BIN" -p "$T" -e "$T/error.log" -c "$T/nginx.conf" -g 'daemon off;' 2>>"$T/error.log" & nginx_pid=$!
for _ in $(seq 50); do
  curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$BACK/" && curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$HTTP/" && break
  sleep 0.1
done
: > "$T/hits"

failed=""
ok()   { echo "ok    $1"; }
bad()  { echo "FAIL  $2"; failed="$failed $1"; }
ask()  { local name=$1; shift; curl -s --max-time 5 --cacert "$T/edge.crt" --resolve "$name:$HTTPS:127.0.0.1" "$@" "https://$name:$HTTPS/"; }
hits() { wc -c < "$T/hits" | tr -d ' '; }

got=$(ask acme.example.test)
[ "$got" = "X-Tenant=acme" ] && ok "1 acme.example.test reaches the backend as acme" || bad 1 "1 acme.example.test: backend saw ${got:-nothing}"

got=$(ask acme.example.test -H "X-Tenant: family" -H "x-tenant: family")
[ "$got" = "X-Tenant=acme" ] && ok "2 a caller's own X-Tenant: family, sent as two copies, is overwritten (backend saw acme only)" \
  || bad 2 "2 a caller's own X-Tenant: family, sent as two copies: backend saw ${got:-nothing}"

got=$(ask acme.example.test -H "X_Tenant: family")
[ "$got" = "X-Tenant=acme" ] && ok "3 a caller's X_Tenant: family never reaches the backend" \
  || bad 3 "3 a caller's X_Tenant: family: backend saw ${got:-nothing}"

got=$(ask family.dev.example.test)
[ "$got" = "X-Tenant=family" ] && ok "4 family.dev.example.test reaches the backend as family" \
  || bad 4 "4 family.dev.example.test: backend saw ${got:-nothing}"

before=$(hits)
got=$(curl -s -k --max-time 5 --resolve "undeclared.example.test:$HTTPS:127.0.0.1" "https://undeclared.example.test:$HTTPS/"); x=$?
if [ "$x" = 35 ] && [ "$(hits)" = "$before" ]; then ok "5 an undeclared name is refused at the TLS handshake"
else bad 5 "5 an undeclared name over https: curl exit $x, backend saw ${got:-nothing}"; fi

before=$(hits)
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: undeclared.example.test" "http://127.0.0.1:$HTTP/")
if [ "$code" = 404 ] && [ "$(hits)" = "$before" ]; then ok "6 an undeclared name over http gets 404 and reaches no backend"
else bad 6 "6 an undeclared name over http: answer $code, backend requests $before -> $(hits)"; fi

printf '%s\n' "tenants:" "  acme:" "    names:" "      - shared.example.test" "  family:" "    names:" \
  "      - shared.example.test" > "$T/twice.yaml"
if out=$(python3 -I "$T/render.py" "$T/twice.yaml" "$T/twice.conf" "$HTTP" "$HTTPS" "$BACK" "$ARM" 2>&1); then
  bad 7 "7 a name declared under two tenants was rendered"
else ok "7 a name declared under two tenants is refused (${out#REFUSED: })"; fi

failed=${failed# }
case "$ARM" in
  '') [ -z "$failed" ] && exit 0; exit 1;;
  noheader) want="1 2 3 4";; underscores|invalidheaders) want="3";; nodefault) want="5 6";; nocheck) want="7";;
esac
if [ "$failed" = "$want" ]; then echo "ARM=$ARM: exactly checks $want failed, as they must"; exit 0; fi
echo "ARM=$ARM: expected checks '$want' to fail, saw '${failed:-none}': this run proves nothing"; exit 1
