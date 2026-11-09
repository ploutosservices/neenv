#!/bin/bash
# drill-environments.sh — "dev, staging and production are made from one declaration and share nothing they were
# not declared to share", as a script.
#
#   ./drill-environments.sh render ENV MANIFEST VALUES
#        prints ENV's environment file: every key the application's MANIFEST needs, with ENV's own value from VALUES,
#        or production's where ENV sets none. A secret reference (secret:<app>/<environment>/<name>) never falls
#        back: the render refuses when ENV names none of its own, or names one of another environment. The one
#        scope any environment may name is secret:<app>/every-environment/<name>, written out in each environment.
#   ./drill-environments.sh check PRODUCTION.env OTHER.env DECISIONS
#        lists every key whose value is identical in the two files, and fails on any that DECISIONS does not
#        declare "inherits". "needs-own", "undecided" and an undeclared key are all failures.
#   ./drill-environments.sh selftest
#        renders the declaration in example/ (beside this script) in a temporary directory and shows one pass and
#        four failures: staging forgetting its own sign-in endpoint; a restore from production that skips writing
#        staging's values back; development naming no secret of its own; development naming production's secret.
#
# File formats (one entry per line, '#' starts a comment, values contain no spaces):
#   MANIFEST   needs: KEY                  the application's: what it needs, never where or what value
#   VALUES     ENV KEY VALUE               the infrastructure's: production, staging, development
#   DECISIONS  KEY DECISION REASON...      inherits | needs-own | undecided, with the reason
# Needs: bash and awk. Nothing else, and no credential.
set -euo pipefail
ME=$0
HERE=$(cd "$(dirname "$0")" && pwd)

render() {   # ENV MANIFEST VALUES
  awk -v env="$1" '
    function scope(v,  p) { split(substr(v, 8), p, "/"); return p[2] }
    function no(msg) { print "FAIL  render " env ": " msg > "/dev/stderr"; bad = 1 }
    /^[[:space:]]*(#|$)/ { next }
    FNR == NR { if ($1 == "needs:") need[++n] = $2; next }
    $1 == env          { own[$2] = $3 }
    $1 == "production" { prod[$2] = $3 }
    END {
      for (i = 1; i <= n; i++) {
        k = need[i]
        if (k in own) v = own[k]
        else if (!(k in prod)) { no(k " is needed and production declares no value for it"); continue }
        else if (prod[k] ~ /^secret:/) { no(k " names no secret of its own, and a secret is never inherited"); continue }
        else v = prod[k]
        if (v ~ /^secret:/ && scope(v) != env && scope(v) != "every-environment") {
          no(k " names " scope(v) "'"'"'s secret (" v ")"); continue
        }
        out[k] = v
      }
      if (bad) exit 1
      for (i = 1; i <= n; i++) print need[i] "=" out[need[i]]
    }' "$2" "$3"
}

check() {   # PRODUCTION.env OTHER.env DECISIONS
  awk -v a="$1" -v b="$2" '
    FILENAME == ARGV[1] { if ($0 !~ /^[[:space:]]*(#|$)/) { d[$1] = $2; r = $0; sub(/^[^ ]+ +[^ ]+ */, "", r); why[$1] = r }; next }
    FILENAME == ARGV[2] { i = index($0, "="); if (i) { k = substr($0, 1, i - 1); va[k] = substr($0, i + 1); order[++n] = k }; next }
    FILENAME == ARGV[3] { i = index($0, "="); if (i) vb[substr($0, 1, i - 1)] = substr($0, i + 1); next }
    END {
      sub(/.*\//, "", a); sub(/.*\//, "", b)
      for (j = 1; j <= n; j++) {
        k = order[j]
        if (!(k in vb)) continue
        if (va[k] != vb[k]) { own++; continue }
        if (d[k] == "inherits")       printf "ok    %-22s identical on purpose: %s\n", k, why[k]
        else if (d[k] == "needs-own") { printf "FAIL  %-22s identical, but declared needs-own: %s\n", k, why[k]; bad++ }
        else if (d[k] != "")          { printf "FAIL  %-22s identical, and the decision is %s: %s\n", k, d[k], why[k]; bad++ }
        else                          { printf "FAIL  %-22s identical, and nothing declares whether it may be\n", k; bad++ }
      }
      printf "%s  %d keys differ, %d identical key(s) not declared inherits (%s vs %s)\n",
             bad ? "RED " : "GREEN", own, bad, a, b
      exit bad ? 1 : 0
    }' "$3" "$1" "$2"
}

# The restore rule. An application keeps some of its environment in its own data (a settings table, here a file).
# A restore copies production's data, settings included; the environment's own values are then written over them and
# read back. Skipping the write leaves the copy pointing at production.
restore() {   # FROM_STORE TO_STORE TO_ENV_FILE write|skip-write
  cp "$1" "$2"
  [ "$4" = skip-write ] && return 0
  local k v
  while IFS='=' read -r k v; do
    awk -v k="$k" -v v="$v" 'BEGIN { FS = OFS = "=" } $1 == k { $0 = k "=" v; f = 1 } { print } END { if (!f) print k "=" v }' \
      "$2" > "$2.new" && mv "$2.new" "$2"
  done < "$3"
  # read back: every value the environment owns must now be in its store
  while IFS='=' read -r k v; do
    grep -qxF "$k=$v" "$2" || { echo "restore: $k did not read back after the write" >&2; return 1; }
  done < "$3"
}

selftest() {
  local w e a b c d f
  e="$HERE/example"
  [ -r "$e/manifest" ] && [ -r "$e/values" ] && [ -r "$e/decisions" ] || { echo "no example/ beside $ME"; exit 2; }
  w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
  cp "$e/manifest" "$e/values" "$e/decisions" "$w/"
  t() { echo "-- $1"; }

  t "the example as declared; staging restored from production and its values written back: must pass"
  render production  "$w/manifest" "$w/values" > "$w/production.env"
  render staging     "$w/manifest" "$w/values" > "$w/staging.env"
  render development "$w/manifest" "$w/values" > "$w/development.env"
  cp "$w/production.env" "$w/production.store"                 # production's own settings rows
  restore "$w/production.store" "$w/staging.store" "$w/staging.env" write
  a=0
  check "$w/production.store" "$w/staging.store"   "$w/decisions" || a=1
  check "$w/production.env"   "$w/development.env" "$w/decisions" || a=1

  t "staging forgets its own sign-in endpoint, so it inherits production's: must fail"
  grep -v '^staging  *SIGN_IN_ISSUER ' "$w/values" > "$w/values.forgot"
  render staging "$w/manifest" "$w/values.forgot" > "$w/staging.forgot.env"
  check "$w/production.env" "$w/staging.forgot.env" "$w/decisions" && b=0 || b=1

  t "staging restored from production without writing its own values back: must fail"
  restore "$w/production.store" "$w/staging.store" "$w/staging.env" skip-write
  check "$w/production.store" "$w/staging.store" "$w/decisions" && c=0 || c=1

  t "development forgets its own sign-in secret: the render must refuse, not inherit production's"
  grep -v '^development  *SIGN_IN_CLIENT_SECRET ' "$w/values" > "$w/values.nosecret"
  render development "$w/manifest" "$w/values.nosecret" > /dev/null 2>"$w/err" && d=0 || d=1
  cat "$w/err"

  t "development names production's sign-in secret: the render must refuse"
  sed 's#^development\(  *SIGN_IN_CLIENT_SECRET  *\).*#development\1secret:notes/production/sign-in#' "$w/values" > "$w/values.prodsecret"
  render development "$w/manifest" "$w/values.prodsecret" > /dev/null 2>"$w/err" && f=0 || f=1
  cat "$w/err"

  if [ "$a$b$c$d$f" = 01111 ]; then echo "SELFTEST passed: one pass, four failures"; exit 0; fi
  echo "SELFTEST FAILED: expected 01111, got $a$b$c$d$f"; exit 1
}

usage() { sed -n '2,22p' "$ME"; exit 2; }
case "${1:-}" in
  selftest) selftest ;;
  render)   [ $# -eq 4 ] || usage; render "$2" "$3" "$4" ;;
  check)    [ $# -eq 4 ] || usage; check "$2" "$3" "$4" ;;
  *)        usage ;;
esac
