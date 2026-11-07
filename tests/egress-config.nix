# The shadow/enforce proxy config is assembled by generated shell in the
# launcher, and its one hard requirement is invisible to eval-level checks:
# the JSON it emits must be exactly what microvm-policy's proxy parses — both
# sides of the contract reject unknown or malformed fields. Extract the region from the
# *built* claude runner (so Nix-to-shell escaping is covered, like
# settings-seed) and feed its output to the real egress-proxy binary, in both
# key modes: host key present (injection) and absent (OAuth passthrough),
# and with the API_BUDGET_* caps the launcher passes on.
{ pkgs, lib, runner, egressProxy }:

pkgs.runCommand "egress-config" { nativeBuildInputs = [ pkgs.jq ]; } ''
  script=${runner}/bin/microvm-run
  awk '/# BEGIN egress-proxy-config/{f=1;next} /# END egress-proxy-config/{f=0} f' "$script" > region.sh
  if [ ! -s region.sh ]; then
    echo "FAIL: no egress-proxy-config region found in the runner — did the markers move?" >&2
    exit 1
  fi

  echo "github.com" > allow.txt
  export _EGRESS_PROXY_CFG=$PWD/cfg.json
  export _EGRESS_PROXY_MODE=enforce
  export _EGRESS_ALLOWLIST_FILE=$PWD/allow.txt
  export EGRESS_AUDIT=$PWD/audit.jsonl
  export _EGRESS_PORTFILE=$PWD/port
  export _EGRESS_USAGE_FILE=$PWD/usage.json _EGRESS_BUDGET_REQUESTS= _EGRESS_BUDGET_TOKENS=

  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  # The proxy exits 0 only on a served shutdown, so "came up" is the portfile
  # appearing; a config the loader rejects dies before writing it.
  starts () {
    rm -f port
    env "$@" ${egressProxy}/bin/egress-proxy -config cfg.json > proxy.log 2>&1 &
    _pid=$!
    for _ in $(seq 1 50); do
      [ -s port ] && break
      sleep 0.1
    done
    kill $_pid 2>/dev/null || true
    wait $_pid 2>/dev/null || true
    [ -s port ]
  }

  ( set -euo pipefail; export ANTHROPIC_API_KEY=host-held; . ./region.sh )
  if grep -q '"keyEnv":"ANTHROPIC_API_KEY"' cfg.json; then
    ok "a host-held key is named for injection"
  else
    bad "config does not name the key env: $(cat cfg.json)"
  fi
  if [ "$(stat -c %a cfg.json)" = "600" ]; then
    ok "config file is mode 600"
  else
    bad "config file is not mode 600"
  fi
  if starts ANTHROPIC_API_KEY=host-held; then
    ok "egress-proxy accepts the generated config (injection mode)"
  else
    bad "egress-proxy refused the generated config: $(cat proxy.log)"
  fi

  ( set -euo pipefail; . ./region.sh )
  if grep -q '"keyEnv":""' cfg.json; then
    ok "an absent host key becomes OAuth passthrough"
  else
    bad "config did not fall back to passthrough: $(cat cfg.json)"
  fi
  if starts; then
    ok "egress-proxy accepts the generated config (passthrough mode)"
  else
    bad "egress-proxy refused the passthrough config: $(cat proxy.log)"
  fi

  if [ "$(jq -c '.endpoints[0] | [.usage, .budget]' cfg.json)" = '["anthropic",null]' ] && [ "$(jq -r .usageFile cfg.json)" = "$PWD/usage.json" ]; then
    ok "without API_BUDGET_* the endpoint is metered, uncapped, and the usage file named"
  else
    bad "unbudgeted config: $(cat cfg.json)"
  fi
  [ -s usage.json ] && ok "the proxy writes the usage file as it starts" || bad "no usage file at start: $(cat proxy.log)"

  # API_BUDGET_REQUESTS / API_BUDGET_TOKENS, as the launcher passes them on;
  # either alone is a budget, the other limit 0 (none).
  for b in "3 1000" "3 -" "- 1000"; do
    set -- $b
    r=$1 t=$2; [ "$r" = - ] && r=""; [ "$t" = - ] && t=""
    ( set -euo pipefail; export _EGRESS_BUDGET_REQUESTS=$r _EGRESS_BUDGET_TOKENS=$t; . ./region.sh )
    want="{\"maxRequests\":''${r:-0},\"maxTokens\":''${t:-0}}"
    if [ "$(jq -c '.endpoints[0].budget' cfg.json)" = "$want" ] && starts; then
      ok "a budget of $b is passed on as $want, and the proxy accepts it"
    else
      bad "budget $b: $(jq -c '.endpoints[0]' cfg.json), proxy: $(cat proxy.log)"
    fi
  done

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
