# Test for VM_TIMEOUT (README "Wall-clock limit"), with the built launcher run
# for real, systemd stubbed and QEMU replaced by a stub that answers QMP
# (tests/lib/stubbed-launcher.nix, QMP=1):
#
#   - when the limit is up the VM's power button is pressed, and the launch
#     exits 124, as timeout(1) does;
#   - a guest that ignores the button is stopped with quit once the grace is
#     up;
#   - a VM that ends on its own first exits as it did, with nothing sent over
#     QMP, and promptly: the watcher does not outlive it;
#   - the limit holds with the launcher killed outright;
#   - the contract and instance.json carry it; a malformed value is refused
#     before any daemon starts.
{ pkgs, lib, runner }:

let
  harness = import ./lib/stubbed-launcher.nix { inherit pkgs runner; };
in
pkgs.runCommand "vm-timeout" { nativeBuildInputs = [ pkgs.socat pkgs.sqlite pkgs.jq ]; } ''
  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  ${harness.preamble}

  export XDG_DATA_HOME=$TMPDIR/data XDG_RUNTIME_DIR=$TMPDIR/rt HOME=$TMPDIR/home WORK_DIR=$TMPDIR/proj NO_PAUSE=1 QMP=1
  unset AGENT_HOME
  mkdir -p $XDG_DATA_HOME $XDG_RUNTIME_DIR $HOME $WORK_DIR
  export HOST_DB=$TMPDIR/host-db.sqlite
  sqlite3 $HOST_DB "CREATE TABLE ValidPaths (path TEXT);"
  NEVER=$TMPDIR/never   # a HOLD file nobody creates: the VM runs until stopped

  # --- the limit is up ------------------------------------------------------------
  t0=$SECONDS
  launch obeys VM_TIMEOUT=2 VM_TIMEOUT_GRACE=5 HOLD=$NEVER
  L=$TMPDIR/obeys
  if [ "$(cat $L/rc)" = 124 ] && grep -q system_powerdown $L/qmp && ! grep -q '"quit"' $L/qmp; then
    ok "at the limit the power button is pressed, and the launch exits 124"
  else bad "obeying guest: rc $(cat $L/rc), qmp: $(cat $L/qmp 2>/dev/null)"; cat $L/out >&2; fi
  [ $(( SECONDS - t0 )) -lt 20 ] && ok "...within seconds of it" || bad "the stop took $(( SECONDS - t0 ))s"
  grep -q "VM_TIMEOUT: the VM was stopped after 2" $L/out && ok "...and says so" || bad "no VM_TIMEOUT message"
  grep -q "wall-clock limit 2: then the power button, and quit 5 later" $L/out \
    && ok "the contract states the limit and the grace" || { bad "contract has no limit line"; grep -A1 resources $L/out >&2; }
  [ "$(jq -c .timeout $L/instance.json)" = '{"seconds":2,"graceSeconds":5}' ] \
    && ok "instance.json carries the limit" || bad "instance.json timeout: $(jq -c .timeout $L/instance.json)"

  launch ignores VM_TIMEOUT=1 VM_TIMEOUT_GRACE=2 HOLD=$NEVER QMP_IGNORE_POWERDOWN=1
  L=$TMPDIR/ignores
  if [ "$(cat $L/rc)" = 124 ] && grep -q system_powerdown $L/qmp && grep -q '"quit"' $L/qmp; then
    ok "a guest that ignores the button is stopped with quit after the grace"
  else bad "ignoring guest: rc $(cat $L/rc), qmp: $(cat $L/qmp 2>/dev/null)"; cat $L/out >&2; fi

  # --- the VM ends first ----------------------------------------------------------
  ( sleep 2; touch $TMPDIR/release ) &
  t0=$SECONDS
  launch early VM_TIMEOUT=1m HOLD=$TMPDIR/release
  L=$TMPDIR/early
  if [ "$(cat $L/rc)" = 0 ] && [ ! -s $L/qmp ] && [ $(( SECONDS - t0 )) -lt 15 ]; then
    ok "a VM that ends before the limit exits 0, promptly, with nothing sent over QMP"
  else bad "early end: rc $(cat $L/rc), $(( SECONDS - t0 ))s, qmp: $(cat $L/qmp 2>/dev/null)"; cat $L/out >&2; fi
  wait

  launch none HOLD=$TMPDIR/release
  [ "$(cat $TMPDIR/none/rc)" = 0 ] && [ "$(jq .timeout $TMPDIR/none/instance.json)" = null ] && ! grep -q 'wall-clock' $TMPDIR/none/out \
    && ok "without VM_TIMEOUT there is no limit, and none is shown" || bad "no-timeout launch: rc $(cat $TMPDIR/none/rc)"

  # --- the launcher killed outright -------------------------------------------------
  launch killed VM_TIMEOUT=3 VM_TIMEOUT_GRACE=5 HOLD=$NEVER &
  for _ in $(seq 1 100); do [ -s $TMPDIR/killed/instance.json ] && break; sleep 0.1; done
  kill -9 "$(jq -r .pid $TMPDIR/killed/instance.json)"
  for _ in $(seq 1 150); do [ -e $TMPDIR/killed/powered-off ] && break; sleep 0.1; done
  [ -e $TMPDIR/killed/powered-off ] && grep -q system_powerdown $TMPDIR/killed/qmp \
    && ok "with the launcher killed outright, the limit still powers the VM off" || bad "the VM outlived its limit once the launcher was killed"
  wait

  # --- values ------------------------------------------------------------------------
  launch bad VM_TIMEOUT=1x
  if [ "$(cat $TMPDIR/bad/rc)" != 0 ] && grep -q "VM_TIMEOUT must be seconds" $TMPDIR/bad/out && [ -z "$(find $TMPDIR/bad -name '*.args')" ]; then
    ok "VM_TIMEOUT=1x is refused before any daemon"
  else bad "VM_TIMEOUT=1x: rc $(cat $TMPDIR/bad/rc)"; cat $TMPDIR/bad/out >&2; fi
  launch zeros VM_TIMEOUT=010 VM_TIMEOUT_GRACE=2m HOLD=$TMPDIR/release
  [ "$(jq -c .timeout $TMPDIR/zeros/instance.json)" = '{"seconds":10,"graceSeconds":120}' ] \
    && ok "010 is ten seconds, 2m is 120" || bad "parsed as $(jq -c .timeout $TMPDIR/zeros/instance.json)"

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
