#!/bin/bash
# drill-clients.sh — does a root carrying Name Constraints keep your own certificates working, refuse a
# certificate for any name outside yours FOR THAT REASON, and can an existing intermediate move under it with no
# key re-issued? Everything is a THROWAWAY PKI in a private temporary directory, deleted on exit. No real key is read.
#
#   usage: ./drill-clients.sh [constraints-file]        (default: name-constraints.txt beside this script)
#   ARM=noconstraint  the same root WITHOUT the constraint: every "refused(constraint)" case must then FAIL (exit 1).
#   CLIENTS=openssl,cross,order,go,java,nginx,chromium,firefox   (default: openssl, cross and order, plus every
#                     other client whose tool is present; a missing tool prints SKIP)
#   DOCKER="sudo -n docker"  how to run docker (Go, Java, nginx and the NSS tools run in containers); default: docker
#   PLAYWRIGHT=<dir of playwright-core>  for Chromium and Firefox (Chromium is the system's own binary)
# Needs: OpenSSL >= 3.0 (not LibreSSL), bash, curl, python3. Images pulled on first use: golang:1.24,
# eclipse-temurin:21-jdk, nginx:1.28, debian:trixie.
# One line per check: PASS/FAIL <client> <case> want=<x> got=<y>. A refusal counts only for the name: OpenSSL's
# 'permitted subtree violation', Go's CANotAuthorizedForThisName, and for browsers (whose error codes are generic)
# refused under the limited root while the same leaf opens under a twin root without the limit. Any other error
# is got=error(...) and FAILs.
# INFO lines record, never fail. Exit 1 on any FAIL, and on any setup step that fails.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NC=$(grep -v '^#' "${1:-$HERE/name-constraints.txt}" | tr -d '\n ')
DOCKER=${DOCKER:-docker}
umask 077
W=$(mktemp -d); NGX=""
trap 'kill $(cat "$W/pids" 2>/dev/null) 2>/dev/null; [ -n "$NGX" ] && $DOCKER rm -f "$NGX" >/dev/null 2>&1; rm -rf "$W"' EXIT
# $W holds the CA keys and stays private. $W/pub is the only directory a container sees: certificates and the
# throwaway leaf keys the servers need, never a CA key.
mkdir "$W/pub" "$W/nss"
must() { "$@" >/dev/null 2>"$W/err" || { echo "SETUP FAILED: $* — $(head -c 300 "$W/err")"; exit 1; }; }
say() { if [ "$3" = "$4" ]; then echo "PASS $1 $2 want=$3 got=$4"; else echo "FAIL $1 $2 want=$3 got=$4"; fi; }
key() { must openssl ecparam -name prime256v1 -genkey -noout -out "$W/$1.key"; }
have() { case ",${CLIENTS:-auto}," in *",$1,"*) return 0;; *",auto,"*) case $1 in openssl|cross|order) return 0;; esac; eval "$2" >/dev/null 2>&1;; *) return 1;; esac; }
freeport() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }

# ── the PKI: root (constrained unless ARM=noconstraint) -> int (servers) and person (people) ──────────────────
rootext="basicConstraints=critical,CA:TRUE,pathlen:1
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash"
[ "${ARM:-}" = noconstraint ] || rootext="$rootext
nameConstraints=$NC"
printf '[r]\n%s\n' "$rootext" > "$W/root.ext"
printf '[c]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' > "$W/ca.ext"
key root; must openssl req -x509 -new -key "$W/root.key" -subj "/O=Drill/CN=Drill Root (our names)" -days 2 -config "$W/root.ext" -extensions r -out "$W/root.crt"
for ca in int person; do key $ca; must openssl req -new -key "$W/$ca.key" -subj "/O=Drill/CN=Drill $ca CA" -out "$W/$ca.csr"
  must openssl x509 -req -in "$W/$ca.csr" -CA "$W/root.crt" -CAkey "$W/root.key" -CAcreateserial -days 2 -extfile "$W/ca.ext" -extensions c -out "$W/$ca.crt"; done

# leaves — case|subjectAltName (empty: none)|subject CN|issuing CA|EKU|expected
# 'refused' always means refused(constraint): refused for the name, not for anything else.
CASES="ours|DNS:app.home.arpa,DNS:host1.home.arpa,IP:10.0.0.13|app.home.arpa|int|serverAuth|ok
plain|DNS:ca.home.arpa|ca.home.arpa|int|serverAuth|ok
foreign|DNS:evil.example.com|evil.example.com|int|serverAuth|refused
mixed|DNS:app.home.arpa,DNS:evil.example.com|app.home.arpa|int|serverAuth|refused
publicip|DNS:app.home.arpa,IP:203.0.113.7|app.home.arpa|int|serverAuth|refused
suffix|DNS:evilhome.arpa|evilhome.arpa|int|serverAuth|refused
ipv6|DNS:app.home.arpa,IP:fd00::13|app.home.arpa|int|serverAuth|refused
cgnat|DNS:app.home.arpa,IP:100.64.0.13|app.home.arpa|int|serverAuth|refused
loopback|DNS:app.home.arpa,IP:127.0.0.1|app.home.arpa|int|serverAuth|ok
email|DNS:app.home.arpa,email:billing@example.test|app.home.arpa|int|serverAuth|ok"
# person certificates: no DNS name, so OpenSSL checks a hostname-like CN against the DNS limit
PCASES="pleaf||alice-laptop@production|person|clientAuth|ok
pleaf-dotted||alice.laptop|person|clientAuth|refused
pleaf-ipsan|IP:10.0.0.5|host.example|person|clientAuth|refused"
leaf() { local n=$1 san=$2 cn=$3 ca=$4 eku=$5; key $n
  must openssl req -new -key "$W/$n.key" -subj "/O=Drill/CN=$cn" -out "$W/$n.csr"
  printf '[s]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=%s\n%sauthorityKeyIdentifier=keyid\n' "$eku" "${san:+subjectAltName=$san
}" > "$W/$n.ext"
  must openssl x509 -req -in "$W/$n.csr" -CA "$W/$ca.crt" -CAkey "$W/$ca.key" -CAcreateserial -days 1 -extfile "$W/$n.ext" -extensions s -out "$W/$n.crt"; }
while IFS='|' read -r n san cn ca eku want; do leaf "$n" "$san" "$cn" "$ca" "$eku"; done <<< "$CASES
$PCASES"
: > "$W/out"; out() { tee -a "$W/out"; }
# OpenSSL's verdict: ok, refused(constraint) for error 47 alone, error(<what it said>) for anything else
ver() { local o; o=$(openssl verify -no-CApath -no-CAstore -CAfile "$1" -untrusted "$2" -purpose "$3" "$4" 2>&1)
  if [ "$o" = "$4: OK" ]; then echo ok; elif grep -q 'permitted subtree violation' <<< "$o"; then echo 'refused(constraint)'
  else echo "error($(grep -m1 -o 'error [0-9]* at [0-9]* depth[^:]*: [a-z ]*' <<< "$o" | tr ' ' _))"; fi; }
w() { [ "$1" = refused ] && echo 'refused(constraint)' || echo "$1"; }

# ── OpenSSL ───────────────────────────────────────────────────────────────────────────────────────────────────
if have openssl true; then
  while IFS='|' read -r n san cn ca eku want; do say openssl $n "$(w $want)" "$(ver "$W/root.crt" "$W/int.crt" sslserver "$W/$n.crt")"; done <<< "$CASES" | out
  while IFS='|' read -r n san cn ca eku want; do say openssl $n "$(w $want)" "$(ver "$W/root.crt" "$W/person.crt" sslclient "$W/$n.crt")"; done <<< "$PCASES" | out
fi

# ── the move: an intermediate made under an OLD root, re-signed by the constrained one (same key, same subject) ─
key old; must openssl req -x509 -new -key "$W/old.key" -subj "/O=Drill/CN=Drill Old Root" -days 2 -addext basicConstraints=critical,CA:TRUE,pathlen:1 -addext keyUsage=critical,keyCertSign,cRLSign -addext subjectKeyIdentifier=hash -out "$W/old.crt"
key oint; must openssl req -new -key "$W/oint.key" -subj "/O=Drill/CN=Drill Intermediate" -out "$W/oint.csr"
must openssl x509 -req -in "$W/oint.csr" -CA "$W/old.crt" -CAkey "$W/old.key" -CAcreateserial -days 2 -extfile "$W/ca.ext" -extensions c -out "$W/oint.crt"
leaf xours "DNS:app.home.arpa" app.home.arpa oint serverAuth; leaf xforeign "DNS:evil.example.com" evil.example.com oint serverAuth
# the cross-certificate: the intermediate's own certificate as input, signed by the new root; only public data.
# The CA extensions are given again, so the authority key identifier names the NEW root (copied, it would name
# the old one and no chain builds); subjectKeyIdentifier=hash gives back the same identifier, because the key is
# the same and the old one was made by the same method — the drill checks that below.
must openssl x509 -in "$W/oint.crt" -CA "$W/root.crt" -CAkey "$W/root.key" -set_serial 0x$(openssl rand -hex 16) -days 2 \
  -extfile "$W/ca.ext" -extensions c -out "$W/cross.crt"
if have cross true; then
  same() { [ "$(openssl x509 -in "$W/oint.crt" -noout $1)" = "$(openssl x509 -in "$W/cross.crt" -noout $1)" ] && echo yes || echo no; }
  say cross same-public-key yes "$(same -pubkey)" | out
  say cross same-subject yes "$(same '-subject -nameopt RFC2253')" | out
  say cross same-subject-key-identifier yes "$(same '-ext subjectKeyIdentifier')" | out
  say cross existing-leaf-under-old-root ok "$(ver "$W/old.crt" "$W/oint.crt" sslserver "$W/xours.crt")" | out
  say cross existing-leaf-under-new-root ok "$(ver "$W/root.crt" "$W/cross.crt" sslserver "$W/xours.crt")" | out
  say cross foreign-leaf-under-old-root ok "$(ver "$W/old.crt" "$W/oint.crt" sslserver "$W/xforeign.crt")" | out
  say cross foreign-leaf-under-new-root 'refused(constraint)' "$(ver "$W/root.crt" "$W/cross.crt" sslserver "$W/xforeign.crt")" | out
  ns=$(ver "$W/root.crt" "$W/oint.crt" sslserver "$W/xours.crt"); case $ns in error*) ns=no-path;; esac
  say cross new-root-without-the-cross no-path "$ns" | out
fi

# ── chain order on the wire: what an OpenSSL-family client holding ONE root accepts, for each order a server sends
if have order true; then
  cat "$W/oint.crt" "$W/cross.crt" > "$W/old-first.pem"; cat "$W/cross.crt" "$W/oint.crt" > "$W/cross-first.pem"
  cat "$W/old.crt" "$W/root.crt" > "$W/both-roots.pem"
  : > "$W/pids"
  for order in old-first cross-first; do p=$(freeport)
    openssl s_server -quiet -accept 127.0.0.1:$p -cert "$W/xours.crt" -key "$W/xours.key" -cert_chain "$W/$order.pem" -www >/dev/null 2>&1 & echo $! >> "$W/pids"
    echo "$order $p" >> "$W/order-ports"; done; sleep 1
  while read -r order p; do for trust in old root both-roots; do
    o=$(echo | openssl s_client -connect 127.0.0.1:$p -servername app.home.arpa -verify_return_error -no-CApath -no-CAstore -CAfile "$W/$trust.$( [ $trust = both-roots ] && echo pem || echo crt)" 2>&1)
    if grep -q 'Verify return code: 0 (ok)' <<< "$o"; then g=ok; elif grep -q 'CONNECTED' <<< "$o"; then g=refused; else g="error(no-connection)"; fi
    case "$order/$trust" in old-first/root|cross-first/old) want=refused;; *) want=ok;; esac
    case $trust in old) h=old-root;; root) h=new-root;; *) h=both-roots;; esac
    say order "$order,client-holds-$h" $want $g; done; done < "$W/order-ports" | out
fi

cp "$W"/*.crt "$W/pub/"; cp "$W"/{ours,pleaf}.key "$W/pub/"   # leaf keys nginx and curl need; no CA key
cat "$W/ours.crt" "$W/int.crt" > "$W/pub/ours.chain"; cat "$W/root.crt" "$W/person.crt" > "$W/pub/clientca.pem"
chmod 755 "$W" "$W/pub"; chmod 644 "$W/pub"/*   # containers read $W/pub only; $W itself lists nothing to others (CA keys are 600)
names=$(echo "$CASES" | cut -d'|' -f1 | tr '\n' ' ')
pnames=$(echo "$PCASES" | cut -d'|' -f1 | tr '\n' ' ')

# ── Go: refused(constraint) only for CertificateInvalidError with reason CANotAuthorizedForThisName ────────────
if have go "$DOCKER info"; then
  cat > "$W/pub/v.go" <<'EOF'
package main
import ("crypto/x509";"encoding/pem";"errors";"fmt";"os";"strings")
func load(p string) *x509.Certificate { b,_:=os.ReadFile(p); d,_:=pem.Decode(b); c,_:=x509.ParseCertificate(d.Bytes); return c }
func main(){ d:=os.Args[1]; r:=x509.NewCertPool(); r.AddCert(load(d+"/root.crt"))
 for _,n:=range os.Args[2:] { ca:="int"; eku:=x509.ExtKeyUsageServerAuth; if strings.HasPrefix(n,"pleaf") {ca="person"; eku=x509.ExtKeyUsageClientAuth}
  i:=x509.NewCertPool(); i.AddCert(load(d+"/"+ca+".crt"))
  _,err:=load(d+"/"+n+".crt").Verify(x509.VerifyOptions{Roots:r,Intermediates:i,KeyUsages:[]x509.ExtKeyUsage{eku}})
  var ce x509.CertificateInvalidError
  if err==nil {fmt.Println(n,"ok")} else if errors.As(err,&ce) && ce.Reason==x509.CANotAuthorizedForThisName {fmt.Println(n,"refused(constraint)")} else {fmt.Println(n,"error("+strings.ReplaceAll(err.Error()," ","_")+")")} } }
EOF
  chmod 644 "$W/pub/v.go"
  $DOCKER run --rm -v "$W/pub":/w:ro -w /tmp golang:1.24 sh -c "cp /w/v.go . && go run v.go /w $names $pnames" > "$W/go.out" 2>&1
  # Go never reads the CN, so a person certificate's dotted CN is not checked: ok, where OpenSSL refuses
  while IFS='|' read -r n san cn ca eku want; do case $n in pleaf-*) want=ok;; esac
    say go $n "$(w $want)" "$(awk -v n=$n '$1==n{print $2}' "$W/go.out")"; done <<< "$CASES
$PCASES" | out
else echo "SKIP go (no docker)"; fi

# ── Java: expected to IGNORE a trust anchor's constraint (it accepts every case); recorded, never failed ────────
if have java "$DOCKER info"; then
  cat > "$W/pub/V.java" <<'EOF'
import java.io.*; import java.security.cert.*; import java.util.*;
public class V { public static void main(String[] a) throws Exception { CertificateFactory f=CertificateFactory.getInstance("X.509");
 X509Certificate r=(X509Certificate)f.generateCertificate(new FileInputStream(a[0]+"/root.crt"));
 for(int k=1;k<a.length;k++){ String n=a[k]; String ca=n.startsWith("pleaf")?"person":"int"; List<Certificate> l=new ArrayList<>();
  l.add(f.generateCertificate(new FileInputStream(a[0]+"/"+n+".crt"))); l.add(f.generateCertificate(new FileInputStream(a[0]+"/"+ca+".crt")));
  PKIXParameters p=new PKIXParameters(Collections.singleton(new TrustAnchor(r,null))); p.setRevocationEnabled(false);
  try{ CertPathValidator.getInstance("PKIX").validate(f.generateCertPath(l),p); System.out.println(n+" ok"); } catch(Exception e){ System.out.println(n+" refused:"+e.getMessage()); } } } }
EOF
  chmod 644 "$W/pub/V.java"
  $DOCKER run --rm -v "$W/pub":/w:ro eclipse-temurin:21-jdk java /w/V.java /w $names pleaf > "$W/java.out" 2>&1
  for n in $names; do echo "INFO java $n got=$(awk -v n=$n '$1==n{print $2}' "$W/java.out") (Java ignores a trust anchor's constraint)"; done
  say java pleaf ok "$(awk '$1=="pleaf"{print $2}' "$W/java.out")" | out
else echo "SKIP java (no docker)"; fi

# ── nginx verifying a person's certificate (ssl_verify_client, depth 2), published on a loopback port ──────────
if have nginx "$DOCKER info"; then
  p=$(freeport); NGX=ncdrill-nginx-$$
  cat > "$W/pub/nginx.conf" <<'EOF'
events {}
http { server { listen 443 ssl; server_name app.home.arpa;
  ssl_certificate /w/ours.chain; ssl_certificate_key /w/ours.key;
  ssl_client_certificate /w/clientca.pem; ssl_verify_client on; ssl_verify_depth 2;
  location / { return 200 "verify=$ssl_client_verify\n"; } } }
EOF
  chmod 644 "$W/pub/nginx.conf"
  $DOCKER run -d --rm --name "$NGX" -p 127.0.0.1:$p:443 -v "$W/pub":/w:ro nginx:1.28 nginx -c /w/nginx.conf -g 'daemon off;' >/dev/null
  up=no; for _ in $(seq 1 30); do curl -s -o /dev/null --resolve app.home.arpa:$p:127.0.0.1 --cacert "$W/root.crt" https://app.home.arpa:$p/ && { up=yes; break; }; sleep 1; done
  if [ $up = yes ]; then
    got=$(curl -s --resolve app.home.arpa:$p:127.0.0.1 --cacert "$W/root.crt" --cert "$W/pleaf.crt" --key "$W/pleaf.key" https://app.home.arpa:$p/)
    [ "$got" = "verify=SUCCESS" ] && got=ok || got="error($got)"; say nginx pleaf ok "$got" | out
    got=$(curl -s --resolve app.home.arpa:$p:127.0.0.1 --cacert "$W/root.crt" https://app.home.arpa:$p/)
    grep -q 'No required SSL certificate was sent' <<< "$got" && got=refused || got="error(${got:0:40})"; say nginx no-certificate refused "$got" | out
  else say nginx up yes no | out; fi
  $DOCKER rm -f "$NGX" >/dev/null 2>&1; NGX=""
else echo "SKIP nginx (no docker)"; fi

# ── browsers through playwright. A browser's error code does not name the constraint (Firefox under playwright
# says SEC_ERROR_UNKNOWN, Chromium ERR_CERT_INVALID), so the reason is proven by a TWIN: the same leaf, same names,
# under a second root identical but for the constraint, which the browser also trusts. refused(constraint) =
# refused under the limited root AND opened under the twin; anything else is error(...).
CHROMIUM=$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)
PLAYWRIGHT=${PLAYWRIGHT:-}
NSSOK="{ command -v certutil || $DOCKER info; }"
B=""; have chromium "[ -n '$PLAYWRIGHT' ] && [ -n '$CHROMIUM' ] && command -v node && $NSSOK" && B="$B chromium"
have firefox "[ -n '$PLAYWRIGHT' ] && command -v node && $NSSOK" && B="$B firefox"
if [ -n "$B" ]; then
  key twin; must openssl req -x509 -new -key "$W/twin.key" -subj "/O=Drill/CN=Drill Twin Root (no limit)" -days 2 -addext basicConstraints=critical,CA:TRUE,pathlen:1 -addext keyUsage=critical,keyCertSign,cRLSign -addext subjectKeyIdentifier=hash -out "$W/twin.crt"
  key tint; must openssl req -new -key "$W/tint.key" -subj "/O=Drill/CN=Drill twin int CA" -out "$W/tint.csr"
  must openssl x509 -req -in "$W/tint.csr" -CA "$W/twin.crt" -CAkey "$W/twin.key" -CAcreateserial -days 2 -extfile "$W/ca.ext" -extensions c -out "$W/tint.crt"
  : >> "$W/pids"
  serve() { local p; p=$(freeport); openssl s_server -quiet -accept 127.0.0.1:$p -cert "$W/$1.crt" -cert_chain "$W/$2.crt" -key "$W/$1.key" -www >/dev/null 2>&1 & echo $! >> "$W/pids"; echo $p; }
  while IFS='|' read -r n san cn ca eku want; do
    leaf "t-$n" "$san" "$cn" tint "$eku"
    echo "$n|$cn|$want|$(serve $n int)|$(serve t-$n tint)" >> "$W/served"; done <<< "$CASES"; sleep 1
  mkdir -p "$W/nss/home/.pki/nssdb" "$W/nss/ff"; cp "$W/root.crt" "$W/twin.crt" "$W/nss/"
  nss="for d in /n/home/.pki/nssdb /n/ff; do certutil -N -d sql:\$d --empty-password && certutil -A -d sql:\$d -n drill -t C,, -i /n/root.crt && certutil -A -d sql:\$d -n twin -t C,, -i /n/twin.crt || exit 1; done"
  if command -v certutil >/dev/null; then sh -c "${nss//\/n/$W/nss}"
  else chmod -R a+rwX "$W/nss"; chmod 755 "$W"   # $W/nss holds the two root CERTIFICATES only, never a key
    $DOCKER run --rm -v "$W/nss":/n debian:trixie sh -c "export DEBIAN_FRONTEND=noninteractive; apt-get -qq update >/dev/null && apt-get -qq install -y libnss3-tools >/dev/null 2>&1 && $nss && chown -R $(id -u):$(id -g) /n"; fi
  cat > "$W/b.mjs" <<'JS'
const pw = await import(process.env.PLAYWRIGHT + '/index.mjs');
const [kind, ...cases] = process.argv.slice(2); const W = process.env.W;
const ctx = kind === 'firefox'
  ? await pw.firefox.launchPersistentContext(W + '/nss/ff', { headless: true })
  : await pw.chromium.launchPersistentContext(W + '/nss/chrome-profile', { headless: true, executablePath: process.env.CHROMIUM,
      env: { ...process.env, HOME: W + '/nss/home' },
      args: ['--no-sandbox', '--host-resolver-rules=' + [...new Set(cases.map(c => c.split(':')[1]))].map(h => `MAP ${h} 127.0.0.1`).join(',')] });
for (const c of cases) { const [id, host, port] = c.split(':'); const p = await ctx.newPage();
  try { await p.goto('https://' + host + ':' + port + '/', { timeout: 15000 });
    console.log(id, (await p.content()).includes('Ciphers') ? 'ok' : 'nopage'); }
  catch (e) { console.log(id, 'err:' + ((String(e.message).match(/[A-Z][A-Z_]{6,}/) || ['unknown'])[0])); }
  await p.close(); }
await ctx.close();
JS
  hosts=$(cut -d'|' -f2 "$W/served" | sort -u | paste -sd,)
  echo "user_pref(\"network.dns.localDomains\", \"$hosts\");" > "$W/nss/ff/user.js"
  for b in $B; do
    W=$W PLAYWRIGHT=$PLAYWRIGHT CHROMIUM=$CHROMIUM node "$W/b.mjs" $b $(awk -F'|' '{print $1":"$2":"$4" t-"$1":"$2":"$5}' "$W/served") > "$W/$b.out" 2>&1
    while IFS='|' read -r n host want p tp; do
      g=$(awk -v n=$n '$1==n{print $2}' "$W/$b.out"); t=$(awk -v n="t-$n" '$1==n{print $2}' "$W/$b.out")
      if [ "$g" = ok ]; then got=ok
      elif [ "${g#err:}" != "$g" ] && [ "$t" = ok ]; then got='refused(constraint)'; echo "INFO $b $n error-code=${g#err:}, twin opened"
      else got="error(${g:-none},twin=${t:-none})"; fi
      say $b $n "$(w $want)" "$got"; done < "$W/served" | out
  done
else echo "SKIP chromium, firefox (need PLAYWRIGHT, node, chromium for Chromium, and certutil or docker)"; fi

f=$(grep -c '^FAIL' "$W/out"); p=$(grep -c '^PASS' "$W/out")
echo "== $p passed, $f failed (constraint: ${ARM:-$NC})"
[ "$f" = 0 ]
