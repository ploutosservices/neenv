#!/bin/bash
# drill-tenant.sh — what a stranger sees of a protected tenant site: it is sent to that site's own sign-in, it cannot
# change the answer by sending the tenant header itself, and a name nobody declared gets nothing from the system.
#
#   ./drill-tenant.sh check URL     URL: a page of a protected tenant site, e.g. https://family.example.org/
#   ./drill-tenant.sh arm URL       URL: a page that is meant to be OPEN. The drill must fail on it; `arm` exits 0
#                                   only when check 1 fails because the page was SERVED (200), which proves the
#                                   drill tells a refusal from a served page. Any other outcome exits 1.
#   OTHER=<tenant key>              a REAL key of another tenant to forge in the header (default: other). A forged
#                                   key of an OPEN tenant is the strong test: if the header were honoured, the
#                                   stranger would be served that tenant's page instead of being sent to sign in.
#   SIGN_IN=<path>                  the site's sign-in path (default: /sso-login)
#   EDGE=<address>                  the edge's address, to send a name nobody declared (check 3; skipped if unset)
# Needs: curl. Sends no credential: everything it checks is what a stranger sees.
set -euo pipefail
mode=${1:-}; URL=${2:-}
[[ "$mode" =~ ^(check|arm)$ && -n "$URL" ]] || { sed -n '2,16p' "$0"; exit 2; }
OTHER=${OTHER:-other}; SIGN_IN=${SIGN_IN:-/sso-login}
host=$(printf '%s' "$URL" | sed -E 's#^https://([^/]+).*#\1#')
[ "$host" != "$URL" ] || { echo "URL must start with https://"; exit 2; }
fail=0
ask() { curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 "$@" || true; }

# 1. A stranger is sent to THIS site's own sign-in over https, by a temporary redirect, and never served the page.
read -r code to <<<"$(ask "$URL")"
if [ "$code" = 000 ]; then echo "FAIL  nothing answered at $URL"; exit 1; fi
if [[ "$code" =~ ^30[27]$ && "$to" == "https://$host$SIGN_IN"* ]]; then
  echo "ok    a stranger is sent to sign in ($code -> $to)"
else
  echo "FAIL  a stranger was answered $code ${to:-(no redirect)}, not a 302/307 to https://$host$SIGN_IN"; fail=1
fi
first=$code

# 2. The tenant header belongs to the edge: a caller that sends it gets exactly the answer it got without it.
read -r code2 to2 <<<"$(ask -H "X-Tenant: $OTHER" "$URL")"
if [ "$code2" = 000 ]; then echo "FAIL  nothing answered with the forged header"; fail=1
elif [ "$code2 $to2" = "$code $to" ]; then echo "ok    a forged X-Tenant: $OTHER changes nothing ($code2)"
else echo "FAIL  with X-Tenant: $OTHER the answer changed: $code2 ${to2:-(no redirect)} against $code ${to:-(no redirect)}"; fail=1
fi

# 3. A name the declaration does not know reaches no tenant (needs EDGE, the edge's address).
if [ -n "${EDGE:-}" ]; then
  # -k: the edge holds no certificate for this name, which is the point. A 404 or 421, or a TLS handshake the edge
  # refuses (curl exit 35), is "no tenant"; no connection at all (exit 7 or 28) means the edge was not reached.
  code3=$(curl -s -o /dev/null -w '%{http_code}' -k --max-time 20 --resolve "undeclared.invalid:443:$EDGE" \
    https://undeclared.invalid/) && x=0 || x=$?
  if [[ "$code3" =~ ^(404|421)$ ]]; then echo "ok    an undeclared name reaches no tenant ($code3)"
  elif [ "$x" = 35 ]; then echo "ok    an undeclared name reaches no tenant (the edge refused the handshake)"
  else echo "FAIL  an undeclared name: answer $code3, curl exit $x (7 or 28: the edge was not reached)"; fail=1; fi
fi

if [ "$mode" = arm ]; then
  if [ "$first" = 200 ]; then echo "ARM: check 1 failed because the open page was served, as it must"; exit 0; fi
  echo "ARM: the open page was answered $first, not 200, so this run proves nothing"; exit 1
fi
exit "$fail"
