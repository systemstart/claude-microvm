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
#     and the egress decision counts, and for a sealed run the egress verdict
#     (microvm-policy egress-report verdict): clean, not-clean, invalid;
#   - API_BUDGET_REQUESTS / API_BUDGET_TOKENS reach the real proxy, which
#     refuses past them; the record names the budget at boot and has what
#     was spent at exit; a bad value, or a budget without the proxy, is
#     refused before boot;
#   - a launch that fails before boot leaves no record, not even an earlier
#     one; a killed launcher leaves `ended` null;
#   - a path the guest can write, or that is not a regular file, is refused.
{ pkgs, lib, runner }:

let
  harness = import ./lib/stubbed-launcher.nix { inherit pkgs runner; };
in
pkgs.runCommand "launch-record" { nativeBuildInputs = [ pkgs.socat pkgs.sqlite pkgs.jq pkgs.curl ]; } ''
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
  # The guest tries a host off the allowlist: a decision as the proxy logs it.
  deny_line='{"time":"t","level":"INFO","msg":"decision","kind":"connect","host":"evil.example.com","port":443,"path":"","decision":"deny","mode":"enforce"}'
  printf '%s\n' "$deny_line" >> "$(jq -r .egress.auditLog $R)"
  touch $HOLD; wait
  if [ "$(cat $TMPDIR/sealed/rc)" = 0 ] && [ "$(jq -c '.ended | [.exitStatus, .timedOut, (.egressDecisions | type)]' $R)" = '[0,false,"object"]' ]; then
    ok "at exit ended has the exit status, timedOut false, and the egress decision counts"
  else bad "ended: $(jq -c .ended $R 2>/dev/null), rc $(cat $TMPDIR/sealed/rc)"; cat $TMPDIR/sealed/out >&2; fi
  if [ "$(jq -r .ended.egressVerdict.outcome $R)" = not-clean ] \
     && jq -r .ended.egressVerdict.summary $R | grep -q '^egress verdict: NOT CLEAN' \
     && [ "$(jq -c .ended.egressVerdict.details $R)" = '["1  deny connect evil.example.com:443"]' ] \
     && grep -q '^egress verdict: NOT CLEAN' $TMPDIR/sealed/out && [ "$(cat $TMPDIR/sealed/rc)" = 0 ]; then
    ok "a sealed run with other egress is judged not clean, the decision named, the exit status untouched"
  else bad "verdict: $(jq -c .ended.egressVerdict $R 2>/dev/null)"; grep -i verdict $TMPDIR/sealed/out >&2; fi

  # --- the verdict: clean, unreadable, and none without a record --------------------------
  launch clean LAUNCH_RECORD=$R EGRESS_POLICY=enforce EGRESS_BUILTIN=0 HOLD=$TMPDIR/release
  [ "$(jq -r .ended.egressVerdict.outcome $R)" = clean ] && [ "$(jq -c .ended.egressVerdict.details $R)" = '[]' ] \
    && ok "a sealed run with nothing but the model API is judged clean" || bad "clean verdict: $(jq -c .ended.egressVerdict $R 2>/dev/null)"
  rm -f $TMPDIR/release2
  launch garbled LAUNCH_RECORD=$R EGRESS_POLICY=shadow HOLD=$TMPDIR/release2 &
  for _ in $(seq 1 300); do [ -e $TMPDIR/garbled/started ] && break; sleep 0.1; done
  printf '{"time":"t","msg":"deci' >> "$(jq -r .egress.auditLog $R)"
  touch $TMPDIR/release2; wait
  [ "$(jq -r .ended.egressVerdict.outcome $R)" = invalid ] && [ "$(cat $TMPDIR/garbled/rc)" = 0 ] \
    && ok "a truncated audit log is judged invalid, never clean" || bad "garbled verdict: $(jq -c .ended.egressVerdict $R 2>/dev/null)"
  # A guest that tries thousands of destinations: a verdict longer than one
  # command-line argument may be (128 KiB) is still recorded whole.
  rm -f $TMPDIR/release3
  launch flood LAUNCH_RECORD=$R EGRESS_POLICY=enforce EGRESS_BUILTIN=0 HOLD=$TMPDIR/release3 &
  for _ in $(seq 1 300); do [ -e $TMPDIR/flood/started ] && break; sleep 0.1; done
  seq 1 5000 | awk '{printf "{\"time\":\"t\",\"level\":\"INFO\",\"msg\":\"decision\",\"kind\":\"connect\",\"host\":\"h%d.probe.example.com\",\"port\":443,\"path\":\"\",\"decision\":\"deny\",\"mode\":\"enforce\"}\n", $1}' \
    >> "$(jq -r .egress.auditLog $R)"
  touch $TMPDIR/release3; wait
  V="$(dirname "$(jq -r .egress.auditLog $R)")/latest.verdict.txt"
  [ "$(cat $TMPDIR/flood/rc)" = 0 ] && [ "$(jq -r .ended.egressVerdict.outcome $R)" = not-clean ] \
    && [ "$(jq '.ended.egressVerdict.details | length' $R)" = 5000 ] && [ "$(wc -c < "$V")" -gt 131072 ] \
    && [ "$(head -n 1 "$V")" = "$(jq -r .ended.egressVerdict.summary $R)" ] \
    && ok "a verdict past 128 KiB is recorded whole, and kept beside the audit log" \
    || { bad "flood verdict: rc $(cat $TMPDIR/flood/rc), $(jq -c '.ended | {o: .egressVerdict.outcome, n: (.egressVerdict.details | length)}' $R 2>/dev/null)"; tail -3 $TMPDIR/flood/out >&2; }
  launch unrecorded EGRESS_POLICY=enforce EGRESS_BUILTIN=0 HOLD=$TMPDIR/release
  ! grep -q 'egress verdict' $TMPDIR/unrecorded/out && ok "without a record no verdict is run" || bad "verdict printed without a record"


  # --- the API budget ---------------------------------------------------------------------
  # The proxy is real; api.anthropic.com is out of the build's reach. A request
  # that cannot reach it spends nothing (502); a batch, whose cost the proxy
  # cannot read, is refused under API_BUDGET_TOKENS without going upstream.
  launch budget LAUNCH_RECORD=$R EGRESS_POLICY=enforce EGRESS_BUILTIN=0 API_BUDGET_REQUESTS=1 API_BUDGET_TOKENS=5000 HOLD=$TMPDIR/budget-release &
  for _ in $(seq 1 300); do [ -e $TMPDIR/budget/started ] && break; sleep 0.1; done
  B=$TMPDIR/budget-boot.json; cp $R $B
  [ "$(jq -c .egress.apiBudget $B)" = '{"maxRequests":1,"maxTokens":5000}' ] && [ "$(jq -c '.egress.endpoints | map(.usage)' $B)" = '["anthropic"]' ] \
    && [ -f "$(jq -r .egress.usageFile $B)" ] \
    && ok "the record names the API budget, the metered endpoint and the usage file" || bad "budget at boot: $(jq -c .egress $B)"
  grep -q 'api budget.*1 requests, 5000 tokens per model endpoint' $TMPDIR/budget/out \
    && ok "the contract shows the budget" || bad "contract: $(grep -i budget $TMPDIR/budget/out)"
  port=$(cat "$(dirname "$(cat $TMPDIR/budget/exported)")/egress.port"); port=''${port##*:}
  codes=""
  for p in /v1/messages /v1/messages /v1/messages/batches; do
    codes="$codes $(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST --data '{}' http://127.0.0.1:$port/anthropic$p || true)"
  done
  [ "$codes" = " 502 502 403" ] && ok "the budget reaches the proxy: an unreachable upstream spends nothing, a batch is refused (403)" \
    || bad "budget statuses:$codes"
  touch $TMPDIR/budget-release; wait
  [ "$(cat $TMPDIR/budget/rc)" = 0 ] \
    && [ "$(jq -c '.ended.apiUsage | map([.prefix, .requests, .refused, .exhausted, .unknownUsage, (.tokens | add), .budget])' $R)" = '[["/anthropic",0,1,false,0,0,{"maxRequests":1,"maxTokens":5000}]]' ] \
    && [ "$(jq -r .ended.egressDecisions.overBudget $R)" = 1 ] \
    && ok "at exit the record has what was spent, and the refusal counted" \
    || bad "budget at exit: rc $(cat $TMPDIR/budget/rc), $(jq -c '.ended | {apiUsage, egressDecisions}' $R)"
  grep -q '^api /anthropic: 0 requests, 0 tokens, 1 refused$' $TMPDIR/budget/out \
    && grep -q '1 request(s) refused under the API budget' $TMPDIR/budget/out \
    && ok "the session end says what the API cost and what the budget refused" || bad "summary: $(grep -i 'api\|budget' $TMPDIR/budget/out)"
  [ "$(jq -r .ended.egressVerdict.outcome $R)" = not-clean ] && jq -r '.ended.egressVerdict.details[]' $R | grep -q over_budget \
    && ok "a run with a request refused under its budget is judged not clean" || bad "budget verdict: $(jq -c .ended.egressVerdict $R)"

  # --- cut short, and open ------------------------------------------------------------
  launch short LAUNCH_RECORD=$R VM_TIMEOUT=1 VM_TIMEOUT_GRACE=2 QMP=1 HOLD=$TMPDIR/never
  [ "$(jq -c '.ended | [.exitStatus, .timedOut, .egressDecisions, .apiUsage, .egressVerdict]' $R)" = '[124,true,null,null,null]' ] \
    && [ "$(jq -r .egress.policy $R)" = open ] && [ "$(jq -r .egress.allowlist $R)" = null ] \
    && ok "a launch VM_TIMEOUT cut short records 124 and timedOut; an open one, no allowlist or decisions" \
    || { bad "short/open record: $(jq -c '{egress, ended}' $R 2>/dev/null), rc $(cat $TMPDIR/short/rc)"; grep -v socat $TMPDIR/short/out | tail -25 >&2; }

  # --- before boot, and killed ----------------------------------------------------------
  echo stale > $R
  launch refused LAUNCH_RECORD=$R AGENT_HOME_MODE=bogus
  [ "$(cat $TMPDIR/refused/rc)" != 0 ] && [ ! -e $R ] \
    && ok "a launch refused before boot leaves no record, not even the earlier one" || bad "refused launch left: $(cat $R 2>/dev/null)"
  echo stale > $R
  launch nowork LAUNCH_RECORD=$R WORK_DIR=$TMPDIR/missing/proj
  [ "$(cat $TMPDIR/nowork/rc)" != 0 ] && [ ! -e $R ] \
    && ok "...and so does one whose WORK_DIR cannot be resolved" || bad "unresolvable WORK_DIR left: $(cat $R 2>/dev/null)"
  # A deny with a wildcard is recorded as given, never as files it matches.
  touch $TMPDIR/cwd/a.example.org
  launch glob LAUNCH_RECORD=$R EGRESS_DENY='*.example.org' HOLD=$TMPDIR/release
  rm -f $TMPDIR/cwd/a.example.org
  [ "$(jq -c .egress.deny $R)" = '["*.example.org"]' ] && ok "a wildcard deny is recorded as given" || bad "deny recorded as $(jq -c .egress.deny $R)"
  [ -z "$(find $TMPDIR/records -maxdepth 1 -name 'run.json.*')" ] && ok "no temporary record file is left behind" || bad "left: $(ls $TMPDIR/records)"
  launch killed LAUNCH_RECORD=$R HOLD=$TMPDIR/never &
  for _ in $(seq 1 300); do [ -e $TMPDIR/killed/started ] && break; sleep 0.1; done
  [ -e $TMPDIR/killed/started ] || { bad "the launch to kill did not start"; tail -5 $TMPDIR/killed/out >&2; }
  kill -9 "$(jq -r .pid $TMPDIR/killed/instance.json)"
  wait || true
  [ -f $R ] && [ "$(jq -r .ended $R)" = null ] && ok "a launcher killed outright leaves its record with ended null" || bad "killed launch record: $(cat $R 2>/dev/null)"
  pkill -f "$STUBS/qemu" 2>/dev/null || true

  # --- a record that cannot be written ------------------------------------------------
  # At exit: the VM's own status stands (124 here); a clean run becomes 1.
  # The directory loses its write permission while the VM runs.
  for case in "short 124 VM_TIMEOUT=1 VM_TIMEOUT_GRACE=2 QMP=1 HOLD=$TMPDIR/never" "clean 1 HOLD=$TMPDIR/later"; do
    set -- $case; n=$1 want=$2; shift 2
    rm -f $TMPDIR/later
    launch nowrite-$n LAUNCH_RECORD=$R "$@" &
    for _ in $(seq 1 300); do [ -e $TMPDIR/nowrite-$n/started ] && break; sleep 0.1; done
    chmod 500 $TMPDIR/records; touch $TMPDIR/later; wait
    chmod 700 $TMPDIR/records
    if [ "$(cat $TMPDIR/nowrite-$n/rc)" = "$want" ] && grep -q "could not complete LAUNCH_RECORD" $TMPDIR/nowrite-$n/out \
       && [ "$(jq -r .ended $R)" = null ] && [ -z "$(find $TMPDIR/records -maxdepth 1 -name 'run.json.*')" ]; then
      ok "a record that cannot be completed is reported, exit $want, ended left null, no temporary file ($n)"
    else bad "unwritable at exit ($n): rc $(cat $TMPDIR/nowrite-$n/rc)"; grep -i record $TMPDIR/nowrite-$n/out >&2; fi
  done
  # At boot: no record, no VM — whether an earlier record is there to remove
  # (old) or the new one cannot be created (new).
  for n in old new; do
    if [ $n = new ]; then rm -f $R; else [ -f $R ] || echo '{}' > $R; fi
    chmod 500 $TMPDIR/records
    launch nowrite-boot-$n LAUNCH_RECORD=$R
    chmod 700 $TMPDIR/records
    [ "$(cat $TMPDIR/nowrite-boot-$n/rc)" != 0 ] && [ ! -e $TMPDIR/nowrite-boot-$n/started ] && grep -q "cannot write LAUNCH_RECORD" $TMPDIR/nowrite-boot-$n/out \
      && ok "a record that cannot be written at boot stops the launch before the VM ($n)" || { bad "unwritable at boot ($n): rc $(cat $TMPDIR/nowrite-boot-$n/rc)"; tail -3 $TMPDIR/nowrite-boot-$n/out >&2; }
  done

  # --- where it may go --------------------------------------------------------------------
  refused () { # name message, then env
    n=$1 msg=$2; shift 2
    launch "$n" "$@"
    if [ "$(cat $TMPDIR/$n/rc)" != 0 ] && grep -q -- "$msg" $TMPDIR/$n/out && [ -z "$(find $TMPDIR/$n -name '*.args')" ]; then
      ok "refused before any daemon: $*"
    else bad "not refused as expected: $* (rc $(cat $TMPDIR/$n/rc))"; cat $TMPDIR/$n/out >&2; fi
  }
  echo keep > $TMPDIR/proj/run.json
  refused in-work "is inside $TMPDIR/proj, which the guest can write" LAUNCH_RECORD=$TMPDIR/proj/run.json
  [ "$(cat $TMPDIR/proj/run.json)" = keep ] && ok "...and the file at the refused path is left alone" || bad "a refused path's file was removed"
  ln -sfn $TMPDIR/proj $TMPDIR/records/via
  refused via-link "is inside $TMPDIR/proj, which the guest can write" LAUNCH_RECORD=$TMPDIR/records/via/run.json
  [ "$(cat $TMPDIR/proj/run.json)" = keep ] && ok "...also through a symlinked parent, and it is left alone" || bad "the file behind a symlinked parent was removed"
  mkdir -p $TMPDIR/shared; chmod 777 $TMPDIR/shared
  refused others-write "must be yours and writable by no one else" LAUNCH_RECORD=$TMPDIR/shared/run.json
  refused in-state "is inside $XDG_DATA_HOME/claude-microvm, which the guest can write" LAUNCH_RECORD=$XDG_DATA_HOME/claude-microvm/run.json
  mkdir -p $TMPDIR/records/adir; ln -sf $TMPDIR/elsewhere $TMPDIR/records/link
  refused a-dir "is not a regular file" LAUNCH_RECORD=$TMPDIR/records/adir
  refused a-link "is not a regular file" LAUNCH_RECORD=$TMPDIR/records/link
  refused no-parent "is not a directory" LAUNCH_RECORD=$TMPDIR/nowhere/run.json
  refused budget-nan "API_BUDGET_TOKENS must be a positive integer" EGRESS_POLICY=enforce API_BUDGET_TOKENS=lots
  refused budget-zero "API_BUDGET_REQUESTS must be a positive integer" EGRESS_POLICY=enforce API_BUDGET_REQUESTS=0
  refused budget-unsealed "need EGRESS_POLICY=shadow|enforce" EGRESS_POLICY=monitor API_BUDGET_REQUESTS=10

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
