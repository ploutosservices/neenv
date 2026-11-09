#!/bin/bash
# drill-dev-box.sh — the walls on a shared development machine, as a script. It builds a throwaway copy of the
# model on the machine it runs on (two project agents, an auditor, their trees, their client keys, one dev
# database), checks every wall from the side of the user it is meant to stop, and removes all of it.
#
#   ./drill-dev-box.sh                    build, check, clean up; exit 0 only if every check passes
#   ARM=<name> ./drill-dev-box.sh         the same, with ONE fix removed; exit 0 only if the matching check FAILS
#        open-homes        agent trees 0755 instead of 0750: the auditor can list an agent's tree
#        shared-key        client keys readable by the agents' group: one agent can read another's key
#        auditor-writes    the auditor is granted write on the dev database
#        foreign-identity  an identity naming another environment is left on the box
#
# Run it as root on a machine you can throw away, or in a container:
#   docker run --rm -v "$PWD":/d:ro debian:trixie bash -c \
#     'apt-get update -qq && apt-get install -y -qq postgresql openssl >/dev/null && /d/drill-dev-box.sh'
#
# It refuses to start if any of its users (app1, app2, auditor) or its group (agents) already exists, so it never
# touches a real account. Everything else lives in one temporary directory. Needs: bash, useradd, runuser,
# openssl, and the PostgreSQL server binaries (initdb, pg_ctl, psql).
set -uo pipefail
ARM=${ARM:-}
AGENTS=(app1 app2)
AUDITOR=auditor
GROUP=agents

[ "$(id -u)" = 0 ] || { echo "run as root (it creates and deletes users), in a container or a throwaway machine"; exit 2; }
case "$ARM" in ""|open-homes|shared-key|auditor-writes|foreign-identity) ;; *) sed -n '2,20p' "$0"; exit 2 ;; esac
for u in "${AGENTS[@]}" "$AUDITOR"; do id "$u" >/dev/null 2>&1 && { echo "user $u already exists; refusing"; exit 2; }; done
getent group "$GROUP" >/dev/null && { echo "group $GROUP already exists; refusing"; exit 2; }
PGBIN=$(dirname "$(ls /usr/lib/postgresql/*/bin/initdb 2>/dev/null | sort -V | tail -1)" 2>/dev/null)
[ -x "$PGBIN/initdb" ] || PGBIN=$(dirname "$(command -v initdb 2>/dev/null)")
[ -x "$PGBIN/initdb" ] || { echo "no PostgreSQL server binaries (initdb) found"; exit 2; }
command -v openssl >/dev/null || { echo "openssl not found"; exit 2; }

T=$(mktemp -d /tmp/dev-box-drill.XXXXXX); chmod 755 "$T"
WORK=$T/work            # the shared work base: every agent's tree is a directory here, not under /home
IDENT=$T/identity       # one directory per identity: <agent>@dev/{cert.pem,key.pem}
PGDATA=$T/pg; PGSOCK=$T/pgsock
cleanup() {
  [ -f "$PGDATA/postmaster.pid" ] && runuser -u pgdrill -- "$PGBIN/pg_ctl" -D "$PGDATA" -m immediate stop >/dev/null 2>&1
  for u in "${AGENTS[@]}" "$AUDITOR" pgdrill; do userdel "$u" >/dev/null 2>&1; done
  groupdel "$GROUP" >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT

# ── build ──────────────────────────────────────────────────────────────────────────────────────────────
groupadd "$GROUP"
mkdir -p "$WORK" "$IDENT" "$PGSOCK"; chmod 755 "$WORK" "$IDENT"
for a in "${AGENTS[@]}" "$AUDITOR"; do
  useradd --home-dir "$WORK/$a" --no-create-home --shell /bin/bash --user-group "$a"
  mkdir -p "$WORK/$a/src"
  echo "notes of $a" > "$WORK/$a/src/notes.txt"
  echo "login-for-$a" > "$WORK/$a/.store-login"          # its own secret-store login: 0600, the owner's alone
  chmod 600 "$WORK/$a/.store-login"
  chown -R "$a:$a" "$WORK/$a"
done
# One actor on a dev box: every project agent reads every other agent's tree; the auditor is not in the group.
for a in "${AGENTS[@]}"; do
  usermod -aG "$GROUP" "$a"
  chgrp "$GROUP" "$WORK/$a"; chmod 750 "$WORK/$a"; chmod -R g+rX "$WORK/$a/src"
done
chmod 700 "$WORK/$AUDITOR"
[ "$ARM" = open-homes ] && chmod 755 "$WORK"/app1 "$WORK"/app2 && chmod -R o+rX "$WORK"/app1/src "$WORK"/app2/src

# A client certificate per agent, CN <agent>@dev, from a throwaway root; the key readable by that agent alone.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$T/ca.key" -out "$T/ca.pem" \
  -days 1 -subj /CN=throwaway-root >/dev/null 2>&1
issue() {   # <identity> <owner>
  local d=$IDENT/$1; mkdir -p "$d"
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$d/key.pem" -out "$d/csr" \
    -subj "/CN=$1" >/dev/null 2>&1
  openssl x509 -req -in "$d/csr" -CA "$T/ca.pem" -CAkey "$T/ca.key" -CAcreateserial -out "$d/cert.pem" -days 1 \
    >/dev/null 2>&1
  rm -f "$d/csr"; chown -R "$2:$2" "$d"; chmod 755 "$d"; chmod 644 "$d/cert.pem"; chmod 600 "$d/key.pem"
}
for a in "${AGENTS[@]}" "$AUDITOR"; do issue "$a@dev" "$a"; done
[ "$ARM" = foreign-identity ] && issue "app1@production" app1
rm -f "$T/ca.key"
if [ "$ARM" = shared-key ]; then for a in "${AGENTS[@]}"; do chgrp "$GROUP" "$IDENT/$a@dev/key.pem"; chmod 640 "$IDENT/$a@dev/key.pem"; done; fi

# One dev database. Peer authentication: the OS user is the database role, so no password exists to share.
useradd --no-create-home --home-dir "$T" --shell /bin/sh pgdrill
mkdir -p "$PGDATA" "$T/pglog"; chown pgdrill "$PGSOCK" "$PGDATA" "$T/pglog"
runuser -u pgdrill -- "$PGBIN/initdb" -D "$PGDATA" -A peer -U pgdrill >/dev/null 2>&1 || { echo "initdb failed"; exit 2; }
runuser -u pgdrill -- "$PGBIN/pg_ctl" -D "$PGDATA" -l "$T/pglog/pg.log" -w \
  -o "-k $PGSOCK -c listen_addresses=''" start >/dev/null 2>&1 || { echo "postgres did not start"; cat "$T/pglog/pg.log"; exit 2; }
chmod 755 "$PGSOCK"
q() { runuser -u "$1" -- "$PGBIN/psql" -h "$PGSOCK" -d devdb -v ON_ERROR_STOP=1 -qAtc "$2" 2>&1; }
runuser -u pgdrill -- "$PGBIN/psql" -h "$PGSOCK" -d postgres -v ON_ERROR_STOP=1 -q >/dev/null <<EOF || { echo "seeding the database failed"; exit 2; }
CREATE DATABASE devdb;
\c devdb
CREATE ROLE app1 LOGIN; CREATE ROLE app2 LOGIN; CREATE ROLE auditor LOGIN;
-- Rights go on tables (GRANT ALL ON DATABASE gives only connect, create and temp). Default privileges carry them to
-- every table the owner makes later; the table below is made AFTER them, so the drill proves they work.
ALTER DEFAULT PRIVILEGES FOR ROLE pgdrill IN SCHEMA public GRANT ALL ON TABLES TO app1, app2;   -- every project agent
ALTER DEFAULT PRIVILEGES FOR ROLE pgdrill IN SCHEMA public GRANT SELECT ON TABLES TO auditor;   -- the auditor reads only
CREATE TABLE notes (who text, body text);
INSERT INTO notes VALUES ('seed', 'a copy of the data, made for development');
EOF
[ "$ARM" = auditor-writes ] && runuser -u pgdrill -- "$PGBIN/psql" -h "$PGSOCK" -d devdb -qc "GRANT INSERT ON notes TO auditor" >/dev/null

# ── check ──────────────────────────────────────────────────────────────────────────────────────────────
fails=(); n=0
ok()   { n=$((n+1)); echo "ok    $n $1"; }
fail() { n=$((n+1)); echo "FAIL  $n $1"; fails+=("$n"); }
can()  { runuser -u "$1" -- sh -c "$2" >/dev/null 2>&1; }
cert_cn() { openssl x509 -in "$1" -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/^ *commonName *= *//p'; }

echo "-- the trees"
can app1 "cat $WORK/app2/src/notes.txt" && ok "app1 reads app2's tree (one actor on a dev box)" \
  || fail "app1 cannot read app2's tree, so the agents cannot see each other's work"
can app1 "touch $WORK/app2/src/by-app1" && fail "app1 wrote into app2's tree" \
  || ok "app1 cannot write into app2's tree"
can app1 "cat $WORK/app2/.store-login" && fail "app1 read app2's secret-store login" \
  || ok "app1 cannot read app2's secret-store login"
can "$AUDITOR" "ls $WORK/app1" && fail "the auditor listed app1's tree, so it can read what the agents hold" \
  || ok "the auditor cannot enter any agent's tree"

echo "-- the client keys"
can app1 "cat $IDENT/app1@dev/key.pem" && ok "app1 reads its own key" || fail "app1 cannot read its own key"
can app1 "cat $IDENT/app2@dev/key.pem" && fail "app1 read app2's key, so app1 can present itself as app2" \
  || ok "app1 cannot read app2's key, so it cannot present itself as app2"
bad=""; for d in "$IDENT"/*/; do cn=$(cert_cn "$d/cert.pem"); case $cn in *@dev) ;; "") bad="$bad (unreadable: $d)" ;; *) bad="$bad $cn" ;; esac; done
[ -z "$bad" ] && ok "every identity on the box names the development environment" \
  || fail "the box holds an identity for another environment:$bad"

echo "-- the dev database"
for a in "${AGENTS[@]}"; do
  out=$(q "$a" "INSERT INTO notes VALUES ('$a', 'written by $a'); SELECT count(*) FROM notes WHERE who='$a'")
  [ "$out" = 1 ] && ok "$a writes the dev database" || fail "$a could not write the dev database: $out"
done
out=$(q "$AUDITOR" "SELECT count(*) FROM notes")
[ "$out" = 3 ] && ok "the auditor reads the dev database (3 rows)" || fail "the auditor could not read: $out"
out=$(q "$AUDITOR" "INSERT INTO notes VALUES ('auditor', 'x')")
case $out in
  *"permission denied"*) ok "the auditor's write is refused by the database (permission denied)" ;;
  "") fail "the auditor wrote to the dev database" ;;
  *) fail "the auditor's write failed for another reason, so nothing was proved: $out" ;;
esac

# ── verdict ────────────────────────────────────────────────────────────────────────────────────────────
# Each arm names the one check it must turn red; any other red means the drill is not measuring what it says.
declare -A WANT=([open-homes]=4 [shared-key]=6 [auditor-writes]=11 [foreign-identity]=7)
if [ -z "$ARM" ]; then
  [ ${#fails[@]} = 0 ] && { echo "WALLS HOLD: $n checks"; exit 0; }
  echo "WALLS BROKEN: check(s) ${fails[*]} failed"; exit 1
fi
if [ "${fails[*]}" = "${WANT[$ARM]}" ]; then echo "ARM $ARM: check ${WANT[$ARM]} failed, as it must, and no other"; exit 0; fi
echo "ARM $ARM: expected check ${WANT[$ARM]} alone to fail, got: ${fails[*]:-none}"; exit 1
