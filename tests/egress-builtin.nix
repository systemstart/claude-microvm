# Test for EGRESS_BUILTIN (README "Egress policy"): with it at 0, a sealed
# session reaches the agent's model endpoints and whatever EGRESS_ALLOW /
# EGRESS_ALLOWLIST name, and nothing else.
#
# The allowlist assembly and the proxy config are generated shell in the
# launcher; both regions are extracted from the *built* runner, as
# egress-config does, and the result is served by the real egress-proxy:
#
#   - by default the built-in lists are in the session allowlist;
#   - EGRESS_BUILTIN=0 leaves them out, keeps EGRESS_ALLOW, and says so in
#     the session contract;
#   - under that allowlist the proxy refuses a CONNECT to a host the built-ins
#     would have allowed, while the model endpoint still passes its decision
#     (there is no network here, so upstream fails after it: 502, not 403);
#   - the launcher refuses a value other than 0 or 1.
{ pkgs, lib, runner, egressProxy }:

pkgs.runCommand "egress-builtin" { nativeBuildInputs = [ pkgs.curl pkgs.jq ]; } ''
  script=${runner}/bin/microvm-run
  region () {
    awk "/# BEGIN $1/{f=1;next} /# END $1/{f=0} f" "$script" > "$1.sh"
    [ -s "$1.sh" ] || { echo "FAIL: no $1 region in the runner — did the markers move?" >&2; exit 1; }
  }
  region egress-allowlist
  region egress-proxy-config

  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  # What the region expects from the launcher around it.
  assemble () { # builtin allow
    ( set -euo pipefail
      EGRESS_POLICY=''${POLICY:-enforce} EGRESS_BUILTIN=$1 EGRESS_ALLOW=$2 EGRESS_DENY=""
      _EGRESS_ALLOWLIST_FILE=$PWD/allow.txt _EGRESS_RULES=$PWD/rules.txt
      _C_B= _C_D= _C_R= _C_G= _C_Y= _C_0=
      _tilde () { printf '%s' "$1"; }
      . ./egress-allowlist.sh )
  }
  hosts () { grep -v '^[[:space:]]*\(#\|$\)' allow.txt | sed 's/[[:space:]]*#.*//' | sort; }

  assemble 1 ""
  if hosts | grep -qx github.com && hosts | grep -qx anthropic.com; then
    ok "by default the built-in lists (common.txt, the flavor's) are allowed"
  else bad "the default allowlist lacks the built-ins: $(hosts | tr '\n' ' ')"; fi
  if grep -q 'EGRESS_BUILTIN=0' rules.txt; then bad "the default contract says the built-ins are off"; else ok "the default contract does not mention EGRESS_BUILTIN"; fi

  assemble 0 ""
  if [ -z "$(hosts)" ]; then ok "EGRESS_BUILTIN=0 alone allows no host"; else bad "EGRESS_BUILTIN=0 still allows: $(hosts | tr '\n' ' ')"; fi
  if grep -q 'built-in lists.*EGRESS_BUILTIN=0' rules.txt; then ok "the contract says the built-in lists are off"; else bad "the contract does not say so:"; cat rules.txt >&2; fi

  POLICY=alert assemble 0 ""
  if grep -q "agent's own API traffic alerts too" rules.txt; then ok "under alert the contract says the agent's API traffic alerts too"
  else bad "alert-mode contract does not say the API host alerts:"; cat rules.txt >&2; fi

  assemble 0 "example.org,example.net:8443"
  if [ "$(hosts | tr '\n' ' ')" = "example.net:8443 example.org " ]; then
    ok "EGRESS_BUILTIN=0 keeps exactly what EGRESS_ALLOW adds"
  else bad "EGRESS_BUILTIN=0 with EGRESS_ALLOW gave: $(hosts | tr '\n' ' ')"; fi

  # --- the proxy, on the strict allowlist ---
  assemble 0 ""
  ( set -euo pipefail
    _EGRESS_PROXY_CFG=$PWD/cfg.json _EGRESS_PROXY_MODE=enforce
    _EGRESS_ALLOWLIST_FILE=$PWD/allow.txt EGRESS_AUDIT=$PWD/audit.jsonl _EGRESS_PORTFILE=$PWD/port
    ANTHROPIC_API_KEY=host-held
    . ./egress-proxy-config.sh )
  ANTHROPIC_API_KEY=host-held ${egressProxy}/bin/egress-proxy -config cfg.json > proxy.log 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do [ -s port ] && break; sleep 0.1; done
  if [ ! -s port ]; then bad "egress-proxy did not start on the strict config: $(cat proxy.log)"; fi
  addr="$(cat port)"; addr="127.0.0.1:''${addr##*:}"

  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -d '{}' "http://$addr/anthropic/v1/messages" || true)"
  if [ "$code" = 502 ]; then ok "the model endpoint passes the proxy's decision (502 only for want of a network)"
  else bad "the model endpoint got HTTP $code, not 502"; fi

  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -d '{}' "http://$addr/anthropic/v1/files" || true)"
  if [ "$code" = 403 ]; then ok "its path grant still applies: /v1/files is refused"
  else bad "/anthropic/v1/files got HTTP $code, not 403"; fi

  if curl -sS -o /dev/null --max-time 10 -p -x "http://$addr" https://github.com/ 2>curl.err; then
    bad "CONNECT github.com went through"
  elif grep -q 403 curl.err; then ok "CONNECT github.com, built-in by default, is refused"
  else bad "CONNECT github.com failed, but not with 403: $(cat curl.err)"; fi

  kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
  if jq -e 'select(.host == "github.com" and .decision == "deny")' audit.jsonl >/dev/null; then
    ok "the audit log records the refused CONNECT"
  else bad "no deny for github.com in the audit log:"; cat audit.jsonl >&2; fi

  # --- the launcher's own check ---
  mkdir -p w
  if EGRESS_BUILTIN=no WORK_DIR=$PWD/w "$script" >/dev/null 2>launch.err; then
    bad "EGRESS_BUILTIN=no was accepted"
  elif grep -q "EGRESS_BUILTIN must be 1" launch.err; then ok "the launcher refuses EGRESS_BUILTIN=no"
  else bad "EGRESS_BUILTIN=no failed, but not with the validation message:"; cat launch.err >&2; fi

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
