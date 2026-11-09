#!/bin/bash
# drill-revocation.sh — does a door that checks revocation refuse a revoked person certificate FOR THAT REASON,
# admit the others, fail closed when a list is missing or stale, and keep working across a root rotation only
# when the new root has signed its own list? Everything is a THROWAWAY PKI in a private temporary directory,
# deleted on exit. No real key is read and nothing is contacted.
#
#   usage: ./drill-revocation.sh
#   ARM=no-revoke   the lost device is never put on the list: "revoked" and "new-root-revoked" must FAIL
#   ARM=no-cross    the person CA is never cross-signed by the new root: every check of a client that holds
#                   the new root alone with a person certificate must FAIL (the four named in EXPECT below)
#   ARM=no-issuer-check  the person edge admits any verified chain: "service-at-person-edge-issuer-check" must FAIL
#   Exit codes, the same in every neenv drill: 0 the run proved what it set out to (no ARM: every check passed;
#   an ARM: exactly that arm's checks failed); 1 it did not; 2 it could not run (a missing tool, a setup step).
# Needs: bash and OpenSSL >= 3.0 (not LibreSSL: macOS ships LibreSSL, use Homebrew's openssl@3). Linux or macOS.
# One line per check: PASS/FAIL <case> want=<x> got=<y>. A refusal counts only for its stated reason; any other
# error is got=error(...) and FAILs.
set -uo pipefail
OPENSSL=${OPENSSL:-openssl}
case "$($OPENSSL version 2>/dev/null)" in OpenSSL\ [3-9]*) ;; *) echo "SETUP FAILED: needs OpenSSL >= 3.0, found: $($OPENSSL version 2>&1)"; exit 2;; esac
case "${ARM:-}" in ''|no-revoke|no-cross|no-issuer-check) ;; *) echo "SETUP FAILED: unknown ARM=${ARM}"; exit 2;; esac
umask 077
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
must() { "$@" >/dev/null 2>"$W/err" || { echo "SETUP FAILED: $* — $(head -c 300 "$W/err")"; exit 2; }; }
key() { must $OPENSSL ecparam -name prime256v1 -genkey -noout -out "$W/$1.key"; }
NOW=$(date +%s)

# ── the hierarchy ───────────────────────────────────────────────────────────────────────────────────────────
# old root (no limit) and new root (limited to home.arpa and private addresses), both pathlen 1.
# One person CA KEY with two certificates: old-issued (old root) and cross (new root). One service CA under the
# new root. Leaves: two person devices (one will be lost), one 24-hour service certificate.
NC='critical,permitted;DNS:home.arpa,permitted;IP:10.0.0.0/255.0.0.0,permitted;IP:172.16.0.0/255.240.0.0,permitted;IP:192.168.0.0/255.255.0.0,permitted;IP:127.0.0.0/255.0.0.0'
printf '[r]\nbasicConstraints=critical,CA:TRUE,pathlen:1\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n' > "$W/old.ext"
{ cat "$W/old.ext"; echo "nameConstraints=$NC"; } > "$W/new.ext"
printf '[c]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' > "$W/ca.ext"
for r in old new; do key $r
  must $OPENSSL req -x509 -new -key "$W/$r.key" -subj "/O=Drill/CN=Drill Root ($r)" -days 30 -config "$W/$r.ext" -extensions r -out "$W/$r.crt"; done
key person; must $OPENSSL req -new -key "$W/person.key" -subj "/O=Drill/OU=person/CN=Drill Person CA" -out "$W/person.csr"
must $OPENSSL x509 -req -in "$W/person.csr" -CA "$W/old.crt" -CAkey "$W/old.key" -set_serial 0x$($OPENSSL rand -hex 16) \
  -days 30 -extfile "$W/ca.ext" -extensions c -out "$W/person-old.crt"
if [ "${ARM:-}" != no-cross ]; then   # the fix: the new root signs the person CA's existing public key again
  must $OPENSSL x509 -in "$W/person-old.crt" -CA "$W/new.crt" -CAkey "$W/new.key" -set_serial 0x$($OPENSSL rand -hex 16) \
    -days 30 -extfile "$W/ca.ext" -extensions c -out "$W/person-cross.crt"
else cp "$W/person-old.crt" "$W/person-cross.crt"; fi   # no cross: only the old-issued certificate exists
key service; must $OPENSSL req -new -key "$W/service.key" -subj "/O=Drill/CN=Drill Service CA" -out "$W/service.csr"
must $OPENSSL x509 -req -in "$W/service.csr" -CA "$W/new.crt" -CAkey "$W/new.key" -set_serial 0x$($OPENSSL rand -hex 16) \
  -days 30 -extfile "$W/ca.ext" -extensions c -out "$W/service.crt"

leaf() { local n=$1 ca=$2 days=$3 subj=$4 ext=$5; key $n
  must $OPENSSL req -new -key "$W/$n.key" -subj "$subj" -out "$W/$n.csr"
  printf '[s]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n%s\nauthorityKeyIdentifier=keyid\n' "$ext" > "$W/$n.ext"
  must $OPENSSL x509 -req -in "$W/$n.csr" -CA "$W/$ca.crt" -CAkey "$W/${ca%-old}.key" -set_serial 0x$($OPENSSL rand -hex 16) \
    -days $days -extfile "$W/$n.ext" -extensions s -out "$W/$n.crt"; }
# person certificates: no SAN, a CN with no dots (see the constrained-root pattern), client authentication, a year
leaf alice person-old 365 "/O=Drill/OU=person/CN=alice-laptop@production" "extendedKeyUsage=clientAuth"
leaf bob   person-old 365 "/O=Drill/OU=person/CN=bob-phone@production"    "extendedKeyUsage=clientAuth"
# service certificate: lives one day; its revocation is its expiry
must $OPENSSL req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$W/app.key" -subj "/O=Drill/CN=app.home.arpa" -out "$W/app.csr"
printf '[s]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=DNS:app.home.arpa\nauthorityKeyIdentifier=keyid\n' > "$W/app.ext"
must $OPENSSL x509 -req -in "$W/app.csr" -CA "$W/service.crt" -CAkey "$W/service.key" -set_serial 0x$($OPENSSL rand -hex 16) \
  -days 1 \
  -extfile "$W/app.ext" -extensions s -out "$W/app.crt"

# ── the revocation lists ────────────────────────────────────────────────────────────────────────────────────
# Each issuer keeps its own list. `openssl ca` needs a small database per issuer; nothing else is used from it.
crl() { local who=$1 cert=$2 hours=$3; local d="$W/db-$who"; mkdir -p "$d"; : > "$d/index.txt"; echo 01 > "$d/crlnumber"
  printf '[ca]\ndefault_ca=c\n[c]\ndatabase=%s/index.txt\ncrlnumber=%s/crlnumber\ndefault_md=sha256\n' "$d" "$d" > "$d/ca.cnf"
  shift 3; for revoked in "$@"; do must $OPENSSL ca -config "$d/ca.cnf" -cert "$W/$cert.crt" -keyfile "$W/$who.key" -revoke "$W/$revoked.crt" -crl_reason keyCompromise; done
  must $OPENSSL ca -config "$d/ca.cnf" -cert "$W/$cert.crt" -keyfile "$W/$who.key" -gencrl -crlhours $hours -out "$W/$who.crl"; }
LOST=bob; [ "${ARM:-}" = no-revoke ] && LOST=""
crl person person-old 48 $LOST   # the online CA's list: two days, re-signed daily and on every revocation
crl old old 8760                 # each root's list: a year, signed by hand with the root key
crl new new 8760
cat "$W/person.crl" "$W/old.crl" > "$W/crl-old-root.pem"
cat "$W/person.crl" "$W/new.crl" > "$W/crl-new-root.pem"

# ── the checks ──────────────────────────────────────────────────────────────────────────────────────────────
# ver <root> <chain> <purpose> <leaf> [crl bundle] [at seconds from now]
# ok | refused(<reason>) for the reasons listed | error(<what OpenSSL said>) for anything else
ver() { local a=() o r; [ -n "${5:-}" ] && a+=(-crl_check_all -CRLfile "$5"); [ -n "${6:-}" ] && a+=(-attime $((NOW + $6)))
  o=$($OPENSSL verify -no-CAfile -no-CApath -no-CAstore -CAfile "$1" -untrusted "$2" -purpose "$3" "${a[@]}" "$4" 2>&1)
  if [ "$o" = "$4: OK" ]; then echo ok; return; fi
  r=$(grep -m1 -o 'error [0-9]* at [0-9]* depth lookup: [A-Za-z ]*' <<< "$o" | sed 's/.*lookup: //; s/ *$//')
  case "$r" in "certificate revoked"|"unable to get certificate CRL"|"CRL has expired"|"certificate has expired") echo "refused($r)";;
    *) echo "error($(printf '%s' "${r:-$o}" | tr '\n' ' ' | head -c 120 | tr ' ' _))";; esac; }
: > "$W/out"
say() { if [ "$2" = "$3" ]; then echo "PASS $1 want=$2 got=$3"; else echo "FAIL $1 want=$2 got=$3"; fi | tee -a "$W/out"; }
OLD=("$W/old.crt" "$W/person-old.crt"); NEW=("$W/new.crt" "$W/person-cross.crt")

# 1. Revocation at a door that trusts the old root and checks every list in the chain
say "kept-device"            ok                                      "$(ver "${OLD[@]}" sslclient "$W/alice.crt" "$W/crl-old-root.pem")"
say "revoked"                "refused(certificate revoked)"          "$(ver "${OLD[@]}" sslclient "$W/bob.crt"   "$W/crl-old-root.pem")"
say "no-revocation-check"    ok                                      "$(ver "${OLD[@]}" sslclient "$W/bob.crt")"
# 2. Fail closed: the whole chain needs a list, and a stale list refuses everyone
say "root-list-missing"      "refused(unable to get certificate CRL)" "$(ver "${OLD[@]}" sslclient "$W/alice.crt" "$W/person.crl")"
say "list-stale"             "refused(CRL has expired)"              "$(ver "${OLD[@]}" sslclient "$W/alice.crt" "$W/crl-old-root.pem" $((72 * 3600)))"
# 3. Rotation: a door that trusts the new root alone reaches the same certificates through the cross-certificate,
#    and needs a list signed by the NEW root, because the chain now ends there
say "new-root-kept-device"   ok                                      "$(ver "${NEW[@]}" sslclient "$W/alice.crt" "$W/crl-new-root.pem")"
say "new-root-revoked"       "refused(certificate revoked)"          "$(ver "${NEW[@]}" sslclient "$W/bob.crt"   "$W/crl-new-root.pem")"
say "new-root-old-list-only" "refused(unable to get certificate CRL)" "$(ver "${NEW[@]}" sslclient "$W/alice.crt" "$W/crl-old-root.pem")"
# 4. A service certificate has no list: it is refused once its one day is over
say "service-today"          ok                                      "$(ver "$W/new.crt" "$W/service.crt" sslserver "$W/app.crt")"
say "service-tomorrow"       "refused(certificate has expired)"      "$(ver "$W/new.crt" "$W/service.crt" sslserver "$W/app.crt" "" $((25 * 3600)))"

# 5. A person edge trusts the root, so a SERVICE certificate sent with its own intermediate builds a valid chain
#    there. Without lists it verifies (the weakness); with the person lists it is refused only because no list for
#    the service CA exists (an accident); the issuer check refuses it for the right reason.
PERSON_CA_DN=$($OPENSSL x509 -in "$W/person-old.crt" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
edge() { local v i; v=$(ver "$W/new.crt" "$W/edge-untrusted.pem" sslclient "$1"); [ "$v" = ok ] || { echo "$v"; return; }
  [ "${ARM:-}" = no-issuer-check ] && { echo ok; return; }
  i=$($OPENSSL x509 -in "$1" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')
  [ "$i" = "$PERSON_CA_DN" ] && echo ok || echo "refused(issuer is not the person CA)"; }
cat "$W/person-cross.crt" "$W/service.crt" > "$W/edge-untrusted.pem"
say "service-chain-at-person-edge"         ok                                       "$(ver "$W/new.crt" "$W/edge-untrusted.pem" sslclient "$W/app.crt")"
say "service-at-person-edge-with-lists"    "refused(unable to get certificate CRL)" "$(ver "$W/new.crt" "$W/edge-untrusted.pem" sslclient "$W/app.crt" "$W/crl-new-root.pem")"
say "service-at-person-edge-issuer-check"  "refused(issuer is not the person CA)"   "$(edge "$W/app.crt")"
say "person-at-person-edge-issuer-check"   ok                                       "$(edge "$W/alice.crt")"

f=$(grep -c '^FAIL' "$W/out"); p=$(grep -c '^PASS' "$W/out")
echo "${ARM:+ARM=$ARM: }$p passed, $f failed"
[ -z "${ARM:-}" ] && { [ "$f" -eq 0 ]; exit; }
# An ARM run passes only when EXACTLY its checks failed: fewer means a check cannot fail, more means the arm broke
# something it was not meant to.
case "$ARM" in
  no-revoke)       EXPECT="new-root-revoked revoked" ;;
  no-cross)        EXPECT="new-root-kept-device new-root-old-list-only new-root-revoked person-at-person-edge-issuer-check" ;;
  no-issuer-check) EXPECT="service-at-person-edge-issuer-check" ;;
esac
GOT=$(awk '/^FAIL/{print $2}' "$W/out" | sort | paste -sd' ')
[ "$GOT" = "$EXPECT" ] && { echo "ARM: exactly the expected checks failed, as they must"; exit 0; }
echo "ARM: expected to fail [$EXPECT], failed [$GOT]"; exit 1
