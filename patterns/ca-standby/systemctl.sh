#!/bin/sh
# systemctl stand-in for the drill's containers: the verbs ca-standby.sh uses, on the one unit step-ca, started as
# the unit does it (its ExecStart, its ConditionFileNotEmpty on ca.json). stop does what systemd does: the kill
# signal, then CONT (a frozen process must be able to die), SIGKILL after a grace, and the pid file goes only when
# the process is gone. Not a general systemctl.
P=/run/step-ca.pid; D=/etc/step-ca; E=/run/step-ca.enabled
alive() { [ -f $P ] && kill -0 "$(cat $P)" 2>/dev/null; }
start() { alive && return 0; [ -s $D/config/ca.json ] || return 0
  # setpriv execs, so the pid is step-ca's own: a signal reaches the CA, as systemctl kill reaches the unit's cgroup
  (exec 9>&-; cd $D && STEPPATH=$D exec setpriv --reuid=step --regid=step --clear-groups step-ca config/ca.json --password-file $D/password.txt) >/var/log/step-ca.log 2>&1 &
  echo $! > $P; sleep 1.5; alive || rm -f $P; return 0; }
stop() { alive || { rm -f $P; return 0; }; pid=$(cat $P); kill -TERM "$pid"; kill -CONT "$pid"
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid"; while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done; rm -f $P; }
case "$1" in
  is-active) alive ;;
  is-enabled) [ -e $E ] ;;
  kill) sig=$(echo "$2" | sed 's/--signal=//'); alive && kill -s "$sig" "$(cat $P)" ;;
  start) start ;;
  stop) stop ;;
  enable) touch $E; [ "${2:-}" = "--now" ] && start; true ;;
  disable) rm -f $E; [ "${2:-}" = "--now" ] && stop; true ;;
  *) exit 0 ;;
esac
