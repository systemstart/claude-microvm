# Test for LAUNCH_RECORD (README "Launch record"), with the built launcher run
# for real, systemd and QEMU stubbed and the egress proxy real
# (tests/lib/stubbed-launcher.nix):
#
#   - a sealed launch records, before boot, what it ran with — workspace,
#     agent home, timeout, resources, egress policy, whether the built-in
#     allowlists applied, the session allowlist and its digest, the audit
#     log, the model endpoints and their path grants, and the names (never
#     the values) of the keys and EXTRA_ENV it passed — with `ended` null;
#   - at exit `ended` has the exit status, whether VM_TIMEOUT cut it short,
#     and the egress decision counts;
#   - a launch that fails before boot leaves no record, not even an earlier
#     one; a killed launcher leaves `ended` null;
#   - a path the guest can write, or that is not a regular file, is refused.
{ pkgs, lib, runner }:

let
  harness = import ./lib/stubbed-launcher.nix { inherit pkgs runner; };
in
pkgs.runCommand "launch-record" { nativeBuildInputs = [ pkgs.socat pkgs.sqlite pkgs.jq ]; } ''
  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  ${harness.preamble}

  export XDG_DATA_HOME=$TMPDIR/data XDG_RUNTIME_DIR=$TMPDIR/rt HOME=$TMPDIR/home WORK_DIR=$TMPDIR/proj NO_PAUSE=1
  unset AGENT_HOME
  mkdir -p $XDG_DATA_HOME $XDG_RUNTIME_DIR $HOME $WORK_DIR $TMPDIR/records
  export HOST_DB=$TMPDIR/host-db.sqlite
  sqlite3 $HOST_DB "CREATE TABLE ValidPaths (path TEXT);"
  R=$TMPDIR/records/run.json

  # --- a sealed launch ----------------------------------------------------------------
  HOLD=$TMPDIR/release
  launch sealed LAUNCH_RECORD=$R EGRESS_POLICY=enforce EGRESS_BUILTIN=0 EGRESS_DENY=example.org \
    AGENT_HOME_MODE=ephemeral WORKSPACE_MODE=ephemeral WORKSPACE_GUARD=1 VM_TIMEOUT=1h VM_MEM=6144 \
    ANTHROPIC_API_KEY=sk-secret-value EXTRA_ENV=FOO=bar-secret,CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 HOLD=$HOLD &
  for _ in $(seq 1 300); do [ -e $TMPDIR/sealed/started ] && break; sleep 0.1; done
  if [ -e $TMPDIR/sealed/started ] && [ -f $R ]; then
    cp $R $TMPDIR/at-boot.json
    B=$TMPDIR/at-boot.json
    [ "$(jq -r .ended $B)" = null ] && ok "before the VM ends the record is there, with ended null" || bad "record at boot: ended $(jq -c .ended $B)"
    [ "$(jq -c .workspace $B)" = "{\"dir\":\"$TMPDIR/proj\",\"mode\":\"ephemeral\",\"guard\":true}" ] \
      && [ "$(jq -r .agentHome.mode $B)" = ephemeral ] && [ "$(jq -c .timeout $B)" = '{"seconds":3600,"graceSeconds":60}' ] \
      && [ "$(jq -r .resources.memMiB $B)" = 6144 ] \
      && ok "it records the workspace, agent home, timeout and resources the launch ran with" \
      || bad "workspace/home/timeout/resources: $(jq -c '{workspace, agentHome, timeout, resources}' $B)"
    E=$(jq -c .egress $B)
    if [ "$(jq -r .egress.policy $B)" = enforce ] && [ "$(jq -r .egress.builtinAllowlists $B)" = false ] \
       && [ "$(jq -c .egress.deny $B)" = '["example.org"]' ] \
       && [ "$(jq -r .egress.allowlist.sha256 $B)" = "$(sha256sum "$(jq -r .egress.allowlist.file $B)" | cut -d' ' -f1)" ] \
       && [ -f "$(jq -r .egress.auditLog $B)" ] \
       && [ "$(jq -c '.egress.endpoints | map([.prefix, .upstream, .allowedPaths])' $B)" = '[["/anthropic","https://api.anthropic.com",["/v1/messages"]]]' ]; then
      ok "it records the egress policy, the built-ins off, the deny, the allowlist with its digest, the audit log, and the endpoints"
    else bad "egress: $E"; fi
    [ "$(jq -c .env $B)" = '{"apiKeys":["ANTHROPIC_API_KEY"],"extraEnv":["FOO","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"],"devShellFromHost":false}' ] \
      && ok "it names the keys and EXTRA_ENV it passed" || bad "env: $(jq -c .env $B)"
    ! grep -q 'sk-secret-value\|bar-secret' $B && ok "...and no value of either" || bad "a secret value is in the record"
    [ "$(stat -c %a $R)" = 600 ] && ok "the record is owner-only" || bad "record mode $(stat -c %a $R)"
  else bad "no record at boot (started: $([ -e $TMPDIR/sealed/started ] && echo yes || echo no))"; cat $TMPDIR/sealed/out >&2; fi
  touch $HOLD; wait
  if [ "$(cat $TMPDIR/sealed/rc)" = 0 ] && [ "$(jq -c '.ended | [.exitStatus, .timedOut, (.egressDecisions | type)]' $R)" = '[0,false,"object"]' ]; then
    ok "at exit ended has the exit status, timedOut false, and the egress decision counts"
  else bad "ended: $(jq -c .ended $R 2>/dev/null), rc $(cat $TMPDIR/sealed/rc)"; cat $TMPDIR/sealed/out >&2; fi

  # --- cut short, and open ------------------------------------------------------------
  launch short LAUNCH_RECORD=$R VM_TIMEOUT=1 VM_TIMEOUT_GRACE=2 QMP=1 HOLD=$TMPDIR/never
  [ "$(jq -c '.ended | [.exitStatus, .timedOut, .egressDecisions]' $R)" = '[124,true,null]' ] \
    && [ "$(jq -r .egress.policy $R)" = open ] && [ "$(jq -r .egress.allowlist $R)" = null ] \
    && ok "a launch VM_TIMEOUT cut short records 124 and timedOut; an open one, no allowlist or decisions" \
    || { bad "short/open record: $(jq -c '{egress, ended}' $R 2>/dev/null), rc $(cat $TMPDIR/short/rc)"; grep -v socat $TMPDIR/short/out | tail -25 >&2; }

  # --- before boot, and killed ----------------------------------------------------------
  echo stale > $R
  launch refused LAUNCH_RECORD=$R AGENT_HOME_MODE=bogus
  [ "$(cat $TMPDIR/refused/rc)" != 0 ] && [ ! -e $R ] \
    && ok "a launch refused before boot leaves no record, not even the earlier one" || bad "refused launch left: $(cat $R 2>/dev/null)"
  launch killed LAUNCH_RECORD=$R HOLD=$TMPDIR/never &
  for _ in $(seq 1 300); do [ -e $TMPDIR/killed/started ] && break; sleep 0.1; done
  [ -e $TMPDIR/killed/started ] || { bad "the launch to kill did not start"; tail -5 $TMPDIR/killed/out >&2; }
  kill -9 "$(jq -r .pid $TMPDIR/killed/instance.json)"
  wait || true
  [ -f $R ] && [ "$(jq -r .ended $R)" = null ] && ok "a launcher killed outright leaves its record with ended null" || bad "killed launch record: $(cat $R 2>/dev/null)"
  pkill -f "$STUBS/qemu" 2>/dev/null || true

  # --- where it may go --------------------------------------------------------------------
  refused () { # name message, then env
    n=$1 msg=$2; shift 2
    launch "$n" "$@"
    if [ "$(cat $TMPDIR/$n/rc)" != 0 ] && grep -q -- "$msg" $TMPDIR/$n/out && [ -z "$(find $TMPDIR/$n -name '*.args')" ]; then
      ok "refused before any daemon: $*"
    else bad "not refused as expected: $* (rc $(cat $TMPDIR/$n/rc))"; cat $TMPDIR/$n/out >&2; fi
  }
  refused in-work "is inside $TMPDIR/proj, which the guest can write" LAUNCH_RECORD=$TMPDIR/proj/run.json
  refused in-state "is inside $XDG_DATA_HOME/claude-microvm, which the guest can write" LAUNCH_RECORD=$XDG_DATA_HOME/claude-microvm/run.json
  mkdir -p $TMPDIR/records/adir; ln -sf $TMPDIR/elsewhere $TMPDIR/records/link
  refused a-dir "is not a regular file" LAUNCH_RECORD=$TMPDIR/records/adir
  refused a-link "is not a regular file" LAUNCH_RECORD=$TMPDIR/records/link
  refused no-parent "is not a directory" LAUNCH_RECORD=$TMPDIR/nowhere/run.json

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
