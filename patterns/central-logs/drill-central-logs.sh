#!/usr/bin/env bash
# drill-central-logs.sh: a sender's journal reaches the store through a door that admits only log senders.
#
#   ./drill-central-logs.sh                  # local: throwaway CA, nginx door, journal-remote, journal-upload; every check must pass
#   ARM=nosubject ./drill-central-logs.sh    # the same door without its subject rule: exactly the 1 "other identity refused" check must FAIL
#   ./drill-central-logs.sh rules            # promtool: the rules' own tests pass, and copies with a guard removed fail them
#   Exit codes, the same in every neenv drill: 0 the run proved what it set out to (no ARM: every check passed;
#   an ARM: exactly that arm's checks failed); 1 it did not; 2 it could not run (a missing tool, a setup step).
#
# local needs bash, curl, openssl, nginx and Debian's systemd-journal-remote package (systemd-journal-remote,
# systemd-journal-upload, journalctl). It runs as any user, on loopback. rules needs promtool and central-logs.yml and
# central-logs.test.yml beside this script.
set -u
set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ARM=${ARM:-}
fails=0
failed=()
ok()   { printf 'ok    %s\n' "${*:2}"; }
fail() { printf 'FAIL  %s\n' "${*:2}"; fails=$((fails + 1)); failed+=("$1"); }

JR=/usr/lib/systemd/systemd-journal-remote
JU=/usr/lib/systemd/systemd-journal-upload

drill_local() {
  local t
  for t in curl openssl journalctl "${NGINX_BIN:-nginx}"; do command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 2; }; done
  [[ -x $JR && -x $JU ]] || { echo "systemd-journal-remote and -upload are required (Debian: apt install systemd-journal-remote)" >&2; exit 2; }
  [[ -z $ARM || $ARM == nosubject ]] || { echo "ARM must be empty or nosubject" >&2; exit 2; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/drill-central-logs.XXXXXX")
  trap 'for p in ${pids:-}; do kill "$p" 2>/dev/null; done; [[ -s $d/nginx.pid ]] && kill "$(cat "$d/nginx.pid")" 2>/dev/null; rm -rf "$d"' EXIT
  cd "$d" || exit 2

  # a throwaway CA, the door's certificate, and three callers: a log sender, another service, and nobody
  {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=drill root" -keyout ca.key -out ca.crt
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=logs.example.test" -keyout door.key -out door.csr
    printf 'subjectAltName=DNS:logs.example.test,IP:127.0.0.1\n' >door.ext
    openssl x509 -req -in door.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -extfile door.ext -out door.crt
    for who in journal-web1@home.arpa other-app@home.arpa; do
      openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$who" -keyout "$who.key" -out "$who.csr"
      openssl x509 -req -in "$who.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -out "$who.crt"
    done
  } >setup.log 2>&1 || { cat setup.log; exit 2; }

  local jport=$(( 20000 + RANDOM % 10000 )) nport=$(( 30000 + RANDOM % 10000 ))
  # the store: journal-remote on loopback, plain HTTP, one file
  mkdir store
  "$JR" --listen-http=127.0.0.1:"$jport" --output="$d/store/remote.journal" >jr.log 2>&1 &
  pids="$!"
  # the store must be up and the port ours before anything is judged; a setup fault is "could not run", never FAIL
  local i
  for i in $(seq 1 25); do curl -s -o /dev/null "http://127.0.0.1:$jport/" && break; sleep 0.2; done
  kill -0 "${pids%% *}" 2>/dev/null && curl -s -o /dev/null "http://127.0.0.1:$jport/" \
    || { echo "journal-remote did not start on $jport:"; cat jr.log; exit 2; }

  # the door: TLS, a client certificate from the CA required, and (unless the arm) only journal-* subjects
  local subject='    if ($ssl_client_s_dn !~ "^CN=journal-[a-z0-9-]+@home\\.arpa$") { return 403; }'
  [[ $ARM == nosubject ]] && subject='    # (arm: no subject rule)'
  cat >nginx.conf <<EOF
worker_processes 1;
pid $d/nginx.pid;
error_log $d/error.log;
events { worker_connections 64; }
http {
    access_log $d/access.log;
    client_body_temp_path $d/tmp-body;
    proxy_temp_path $d/tmp-proxy;
    fastcgi_temp_path $d/tmp-fastcgi;
    uwsgi_temp_path $d/tmp-uwsgi;
    scgi_temp_path $d/tmp-scgi;
    server {
        listen 127.0.0.1:$nport ssl;
        server_name logs.example.test;
        ssl_certificate $d/door.crt;
        ssl_certificate_key $d/door.key;
        ssl_client_certificate $d/ca.crt;
        ssl_verify_client optional;
        if (\$ssl_client_verify != SUCCESS) { return 403; }
$subject
        client_max_body_size 0;
        proxy_request_buffering off;
        location / {
            proxy_pass http://127.0.0.1:$jport;
            proxy_http_version 1.1;
        }
    }
}
EOF
  local nginx=${NGINX_BIN:-nginx}
  "$nginx" -t -q -p "$d" -c "$d/nginx.conf" -e "$d/error.log" 2>/dev/null || { cat error.log; exit 2; }
  "$nginx" -p "$d" -c "$d/nginx.conf" -e "$d/error.log" -g 'daemon off;' </dev/null >/dev/null 2>&1 &
  pids="$pids $!"
  for i in $(seq 1 25); do [[ -s $d/nginx.pid ]] && curl -sk -o /dev/null "https://127.0.0.1:$nport/" && break; sleep 0.2; done
  [[ -s $d/nginx.pid ]] && curl -sk -o /dev/null "https://127.0.0.1:$nport/" || { echo "nginx did not start on $nport"; cat error.log; exit 2; }

  # a small journal to send: three entries in journal export format, made into a journal file by journal-remote itself.
  # An entry needs both timestamps and a boot id, or the importer drops it ("Entry is invalid").
  local marker="drill-$RANDOM-$RANDOM" boot; boot=$(openssl rand -hex 16)
  { for i in 1 2 3; do printf 'MESSAGE=%s line %s\n_HOSTNAME=web1\nSYSLOG_IDENTIFIER=drill\n__REALTIME_TIMESTAMP=%s000000\n__MONOTONIC_TIMESTAMP=%s000000\n_BOOT_ID=%s\n\n' "$marker" "$i" "$(( $(date +%s) - 10 + i ))" "$i" "$boot"; done; } \
    | "$JR" --output="$d/source.journal" - >>setup.log 2>&1 || { echo "could not make the source journal"; cat setup.log; exit 2; }

  tag() { local t=${1%%@*}; echo "${t:-none}"; }   # a log file's name: the identity before its @
  send() {   # $1 = identity ('' for none); prints the HTTP outcome as journal-upload reports it
    local args=(--url="https://127.0.0.1:$nport" --trust="$d/ca.crt" --file="$d/source.journal" --follow=no)   # send the file, then exit
    [[ -n $1 ]] && args+=(--key="$d/$1.key" --cert="$d/$1.crt")
    # On a machine that is itself a sender, journal-upload also reads its URL from /etc/systemd/journal-upload.conf and
    # refuses two. Hide that file in a private mount namespace (no root needed where user namespaces are allowed).
    if grep -qs '^URL=' /etc/systemd/journal-upload.conf /etc/systemd/journal-upload.conf.d/*.conf; then
      timeout 20 unshare -rm sh -c 'mount --bind /dev/null /etc/systemd/journal-upload.conf &&
        { [ ! -d /etc/systemd/journal-upload.conf.d ] || mount -t tmpfs none /etc/systemd/journal-upload.conf.d; } &&
        exec "$@"' sh "$JU" "${args[@]}" >"send-$(tag "$1").log" 2>&1
    else
      timeout 20 "$JU" "${args[@]}" >"send-$(tag "$1").log" 2>&1
    fi
  }
  # where the machine's own upload configuration must be hidden, the namespace that hides it must work at all
  if grep -qs '^URL=' /etc/systemd/journal-upload.conf /etc/systemd/journal-upload.conf.d/*.conf; then
    unshare -rm true 2>/dev/null || { echo "this machine is a log sender and user namespaces are not allowed: run elsewhere"; exit 2; }
  fi
  echo "door on 127.0.0.1:$nport, store on 127.0.0.1:$jport, $([[ $ARM == nosubject ]] && echo 'no subject rule' || echo 'journal-* only')"

  if send journal-web1@home.arpa; then ok sender "a log sender's upload is accepted"
  else fail sender "a log sender's upload was refused: $(tail -1 send-journal-web1.log)"; fi
  sleep 1
  local got; got=$(journalctl --file="$d/store/remote.journal" -o cat 2>/dev/null | grep -c "^$marker line")
  if [[ $got == 3 ]]; then ok stored "all 3 of its entries are in the store"; else fail stored "the store holds $got of its 3 entries"; fi
  local host; host=$(journalctl --file="$d/store/remote.journal" -o export 2>/dev/null | grep -m1 '^_HOSTNAME=' )
  # the stored _HOSTNAME is the SENDER'S CLAIM, kept as sent: it says which machine a line is about, not who sent it
  if [[ $host == _HOSTNAME=web1 ]]; then ok host "each entry keeps the host name it was sent with"; else fail host "the stored entry names '${host:-nothing}', not web1"; fi

  # a refusal counts only as the door's 403: a TLS failure or a dead store would also "refuse", and prove nothing
  refused() { ! send "$1" && grep -q 'failed with code 403' "send-$(tag "$1").log"; }   # journal-upload's own words
  if refused other-app@home.arpa; then ok other "another service's certificate is refused (403)"
  else fail other "another service's certificate was not refused with 403: $(tail -1 send-other-app.log)"; fi
  # journal-upload cannot send without a certificate at all, so the caller with none is curl
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$d/ca.crt" -X POST \
    -H 'Content-Type: application/vnd.fdo.journal' --data-binary $'MESSAGE=nobody\n\n' "https://127.0.0.1:$nport/upload")
  if [[ $code == 403 ]]; then ok nocert "a caller with no certificate is refused (403)"
  else fail nocert "a caller with no certificate got $code, not 403"; fi
  local after; after=$(journalctl --file="$d/store/remote.journal" -o cat 2>/dev/null | grep -c "^$marker line")
  if [[ $ARM == nosubject || $after == 3 ]]; then ok unchanged "the refused callers added nothing to the store"
  else fail unchanged "the store holds $after entries after the refused callers, not 3"; fi
}

drill_rules() {
  command -v promtool >/dev/null || { echo "promtool is required" >&2; exit 2; }
  [[ -f $HERE/central-logs.yml && -f $HERE/central-logs.test.yml ]] || { echo "central-logs.yml and central-logs.test.yml must be beside this script" >&2; exit 2; }
  [[ -z $ARM ]] || { echo "rules carries its arms inside; run it without ARM" >&2; exit 2; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/drill-central-logs.XXXXXX")
  trap 'rm -rf "$d"' EXIT
  promtool check rules "$HERE/central-logs.yml" >/dev/null || { echo "promtool refuses central-logs.yml"; exit 2; }
  run_case() {   # $1 name, $2 sed expression ('' for none), $3 pass|fail
    mkdir -p "$d/$1"
    if [[ -n $2 ]]; then sed -E "$2" "$HERE/central-logs.yml" >"$d/$1/central-logs.yml"; else cp "$HERE/central-logs.yml" "$d/$1/"; fi
    [[ -n $2 ]] && cmp -s "$HERE/central-logs.yml" "$d/$1/central-logs.yml" && { echo "case $1 changed nothing in the rules"; exit 2; }
    cp "$HERE/central-logs.test.yml" "$d/$1/"
    local got; if promtool test rules "$d/$1/central-logs.test.yml" >"$d/$1/out" 2>&1; then got=pass; else got=fail; fi
    if [[ $got == "$3" ]]; then ok "$1" "$1: the tests $got, as they must"; else fail "$1" "$1: the tests $got, not $3"; sed 's/^/      /' "$d/$1/out" | head -20; fi
  }
  run_case as-published '' pass
  # no `unless`: every server that answers is reported quiet, the ones the store hears included
  run_case no-unless '/^ *unless on \(instance\)/d' fail
  # no `absent`: a receiver whose facts stopped arriving is never reported
  run_case no-absent 's/ or absent\(central_logs_read_ok\)//' fail
  # no file age: a timer that stopped, its last file still served, is never reported
  run_case no-file-age '/or time\(\) - max\(node_textfile_mtime_seconds/d' fail
}

case ${1:-local} in
  local) drill_local ;;
  rules) drill_rules ;;
  *)     sed -n '2,12p' "$0"; exit 2 ;;
esac

if [[ $ARM == nosubject ]]; then
  if [[ "${failed[*]}" == "other" ]]; then echo "ARM: exactly the 'other identity refused' check failed without the subject rule, as it must"; exit 0; fi
  echo "ARM: the checks that failed without the subject rule were '${failed[*]}', not 'other': the drill cannot tell the rule from its absence"; exit 1
fi
(( fails == 0 )) || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
