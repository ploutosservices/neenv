#!/bin/sh
# cp stand-in for the drill: a copy of the CA's database fails while /run/fail-cp exists (the error-path thaw case) and
# hangs while /run/slow-cp exists (a sender killed mid-freeze); otherwise the real cp.
case " $* " in *" /etc/step-ca/db "*)
  [ -e /run/fail-cp ] && { echo "cp: drill failure" >&2; exit 1; }
  [ -e /run/slow-cp ] && sleep 30 ;; esac
exec /bin/cp "$@"
