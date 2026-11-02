# microvm-stop (scripts/microvm-stop.sh), against fake launches: an instance
# dir with its instance.json, a QMP socket served by a stand-in that logs what
# it is sent and "powers off" on system_powerdown or quit, and a lock held — as
# the launcher holds it — until the VM is off, then the dir removed.
#
#   - finds a launch by ID, by instance dir, or as the only one running, and
#     lists them rather than guess when there are several;
#   - presses the power button (qmp_capabilities, then system_powerdown), or
#     with --force sends quit, and waits until the launch has gone;
#   - says so, without touching QMP, when a launch is no longer running;
#   - gives up after --timeout when the guest ignores the button, and says what
#     --force is for;
#   - fails clearly for an unknown launch, a refusal from QEMU, a socket with
#     nothing behind it, and bad arguments.
#
# tests/launch-scope.nix stops real launches with it, scoped and unscoped.
{ pkgs, lib, microvmStop }:

pkgs.runCommand "microvm-stop" { nativeBuildInputs = with pkgs; [ jq socat util-linux ]; } ''
  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  export XDG_RUNTIME_DIR=$TMPDIR/rt
  VMS=$XDG_RUNTIME_DIR/claude-microvm/vms
  mkdir -p $VMS
  stop=${microvmStop}/bin/microvm-stop

  # The QMP stand-in, one per connection: greets, answers, logs each command
  # to $QMP_LOG, and marks the VM off on system_powerdown or quit — unless
  # REFUSE is set, when it answers those with an error.
  cat > $TMPDIR/qmp <<'EOF'
  #!${pkgs.bash}/bin/bash
  echo '{"QMP": {"version": {}, "capabilities": []}}'
  while IFS= read -r line; do
    echo "$line" >> "$QMP_LOG"
    case "$line" in
      *system_powerdown*|*'"quit"'*)
        if [ -n "$REFUSE" ]; then echo '{"error": {"class": "GenericError", "desc": "refused"}}'
        else echo '{"return": {}}'; touch "$OFF"; fi ;;
      *) echo '{"return": {}}' ;;
    esac
  done
  EOF
  chmod +x $TMPDIR/qmp

  pids=()
  # fake <id> [never|refuse|noqmp|stale]: a launch, running unless stale.
  fake () {
    local id=$1 how=''${2:-} d=$VMS/$1
    mkdir -p $d; : > $d/lock
    jq -n --arg id $id --arg work /home/u/$id --arg qmp $d/qmp.sock \
      '{version: 1, id: $id, work: $work, sockets: {qmp: $qmp}}' > $d/instance.json
    [ "$how" = stale ] && return
    if [ "$how" != noqmp ]; then
      QMP_LOG=$TMPDIR/$id.qmp OFF=$TMPDIR/$id.off REFUSE=$([ "$how" = refuse ] && echo 1) \
        socat UNIX-LISTEN:$d/qmp.sock,fork EXEC:$TMPDIR/qmp &
      pids+=($!)
      for _ in $(seq 1 50); do [ -S $d/qmp.sock ] && break; sleep 0.1; done
    fi
    # The launcher's part: hold the lock until the VM is off, then clean up.
    if [ "$how" = never ]; then hold="sleep 600"
    else hold="while [ ! -e $TMPDIR/$id.off ]; do sleep 0.1; done; rm -rf $d"; fi
    flock $d/lock sh -c "$hold" &
    pids+=($!)
    for _ in $(seq 1 50); do flock -n $d/lock true || break; sleep 0.1; done
  }
  run () { rc=0; msg=$("$stop" "$@" 2>&1) || rc=$?; }

  # --- finding a launch, and stopping it ----------------------------------------
  fake aaaaaaaaaaaa
  run aaaaaaaaaaaa
  if [ $rc = 0 ] && grep -q 'aaaaaaaaaaaa stopped' <<< "$msg" && [ ! -e $VMS/aaaaaaaaaaaa ]; then
    ok "by ID: powers the launch off and waits until it has gone"
  else bad "by ID: rc $rc: $msg"; fi
  if [ "$(cat $TMPDIR/aaaaaaaaaaaa.qmp 2>/dev/null)" = $'{"execute":"qmp_capabilities"}\n{"execute":"system_powerdown"}' ]; then
    ok "...by sending qmp_capabilities, then system_powerdown — the power button"
  else bad "QMP got: $(cat $TMPDIR/aaaaaaaaaaaa.qmp 2>/dev/null)"; fi

  fake bbbbbbbbbbbb
  run $VMS/bbbbbbbbbbbb/
  [ $rc = 0 ] && grep -q 'bbbbbbbbbbbb stopped' <<< "$msg" && ok "by instance dir" || bad "by dir: rc $rc: $msg"

  fake cccccccccccc
  run
  [ $rc = 0 ] && grep -q 'cccccccccccc stopped' <<< "$msg" && ok "with no argument, stops the only running launch" || bad "only one: rc $rc: $msg"

  fake dddddddddddd; fake eeeeeeeeeeee
  run
  if [ $rc = 1 ] && grep -q '2 launches are running' <<< "$msg" && grep -q dddddddddddd <<< "$msg" \
     && grep -q /home/u/eeeeeeeeeeee <<< "$msg" && [ ! -e $TMPDIR/dddddddddddd.qmp ] && [ ! -e $TMPDIR/eeeeeeeeeeee.qmp ]; then
    ok "with no argument and two running, lists them (ID and project) and stops neither"
  else bad "two running: rc $rc: $msg"; fi

  run --force dddddddddddd
  if [ $rc = 0 ] && grep -q 'dddddddddddd stopped' <<< "$msg" && grep -qx '{"execute":"quit"}' $TMPDIR/dddddddddddd.qmp \
     && ! grep -q system_powerdown $TMPDIR/dddddddddddd.qmp; then
    ok "--force sends quit instead of the power button"
  else bad "--force: rc $rc: $msg; QMP got $(cat $TMPDIR/dddddddddddd.qmp 2>/dev/null)"; fi
  run eeeeeeeeeeee

  # --- launches that cannot be, or need not be, stopped --------------------------
  fake ffffffffffff stale
  run ffffffffffff
  if [ $rc = 0 ] && grep -q 'not running' <<< "$msg" && [ ! -e $TMPDIR/ffffffffffff.qmp ]; then
    ok "a launch whose lock is free is reported as not running, and QMP is not touched"
  else bad "stale: rc $rc: $msg"; fi
  rm -rf $VMS/ffffffffffff

  fake 111111111111 never
  start=$SECONDS; run --timeout 2 111111111111
  if [ $rc = 3 ] && grep -q 'still running after 2s' <<< "$msg" && grep -q -- '--force' <<< "$msg" && [ $((SECONDS - start)) -lt 10 ]; then
    ok "a guest that ignores the button: gives up after --timeout (exit 3) and points at --force"
  else bad "timeout: rc $rc: $msg"; fi

  fake 222222222222 refuse
  run 222222222222
  [ $rc = 1 ] && grep -q 'QEMU refused' <<< "$msg" && ok "a QMP error is reported (exit 1)" || bad "refused: rc $rc: $msg"

  fake 333333333333 noqmp
  run 333333333333
  [ $rc = 1 ] && grep -q 'cannot reach QEMU' <<< "$msg" && ok "a socket with nothing behind it is reported (exit 1)" || bad "unreachable: rc $rc: $msg"

  # instance.json describes a launch but must not direct microvm-stop: the
  # socket is where the layout puts it, and the file's id must be its dir's.
  fake 444444444444; fake 555555555555
  jq --arg qmp $VMS/444444444444/qmp.sock '.sockets.qmp = $qmp' $VMS/555555555555/instance.json > $TMPDIR/j \
    && mv $TMPDIR/j $VMS/555555555555/instance.json
  run 555555555555
  if [ $rc = 0 ] && grep -q system_powerdown $TMPDIR/555555555555.qmp && [ ! -e $TMPDIR/444444444444.qmp ] \
     && [ -d $VMS/444444444444 ]; then
    ok "an instance.json naming another launch's socket: the launch's own qmp.sock is used, the other left alone"
  else bad "misdirected socket: rc $rc: $msg; 444 QMP got $(cat $TMPDIR/444444444444.qmp 2>/dev/null)"; fi
  run 444444444444
  fake 666666666666
  jq '.id = "777777777777"' $VMS/666666666666/instance.json > $TMPDIR/j && mv $TMPDIR/j $VMS/666666666666/instance.json
  run 666666666666
  if [ $rc = 1 ] && grep -q 'is not this launch' <<< "$msg" && [ ! -e $TMPDIR/666666666666.qmp ]; then
    ok "an instance.json whose id is not its dir's is refused, and QMP is not touched"
  else bad "mismatched id: rc $rc: $msg"; fi
  touch $TMPDIR/666666666666.off

  run 999999999999
  [ $rc = 1 ] && grep -q 'no launch 999999999999' <<< "$msg" && ok "an unknown ID is reported (exit 1)" || bad "unknown: rc $rc: $msg"
  run not-an-id
  [ $rc = 2 ] && ok "an argument that is neither an ID nor an instance dir is a usage error (exit 2)" || bad "bad arg: rc $rc: $msg"
  run --timeout soon aaaaaaaaaaaa
  [ $rc = 2 ] && ok "a --timeout that is not whole seconds is a usage error" || bad "bad timeout: rc $rc: $msg"

  kill "''${pids[@]}" 2>/dev/null || true
  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
