# Behavioural test for the AGENT_SETTINGS pre-seed (flake.nix, host-side
# runner). The knob's value is its semantics — seed-not-sync, in-VM edits
# surviving, host changes winning, loud refusal of bad input — and every one of
# those is a runtime behaviour of the generated shell, invisible to eval-level
# assertions.
#
# The region is extracted from the *built* claude runner rather than from
# flake.nix, so the Nix-to-shell escaping is covered. Only the claude runner is
# used: the settingsFile == null branch is a two-line warning, and exercising
# it would pull a second full VM closure into this check to grep one string.
{ pkgs, lib, runner }:

pkgs.runCommand "settings-seed" { } ''
  script=${runner}/bin/microvm-run
  awk '/# BEGIN settings-seed/{f=1;next} /# END settings-seed/{f=0} f' "$script" > seed.sh
  if [ ! -s seed.sh ]; then
    echo "FAIL: no settings-seed region found in the runner — did the markers move?" >&2
    exit 1
  fi

  export AGENT_DIR=$TMPDIR/agent
  mkdir -p "$AGENT_DIR"
  echo '{"model":"opus"}' > good.json
  echo '{broken' > bad.json

  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  # Run the region as the runner would: set -euo pipefail, in a subshell so a
  # refusal (exit 1) fails the scenario, not the test driver.
  seed () { ( set -euo pipefail; AGENT_SETTINGS="$1"; . ./seed.sh ); }

  if _seedout=$(seed "$PWD/good.json") \
     && [ "$(cat "$AGENT_DIR/.claude/settings.json")" = '{"model":"opus"}' ] \
     && [ -s "$AGENT_DIR/.microvm-settings.hash" ]; then
    ok "a fresh agent home is seeded, hash sidecar written"
  else
    bad "fresh seed did not land"
  fi

  if [ "$(stat -c %a "$AGENT_DIR/.claude/settings.json")" = "600" ]; then
    ok "seeded file is mode 600"
  else
    bad "seeded file is not mode 600"
  fi

  if _seedout=$(seed "$PWD/good.json") && [ -z "$_seedout" ]; then
    ok "an unchanged source relaunch is silent and touches nothing"
  else
    bad "relaunch with unchanged source was not a quiet no-op: [$_seedout]"
  fi

  echo '{"model":"sonnet"}' > "$AGENT_DIR/.claude/settings.json"
  seed "$PWD/good.json" > /dev/null
  if grep -q sonnet "$AGENT_DIR/.claude/settings.json"; then
    ok "an in-VM edit survives while the source is unchanged"
  else
    bad "in-VM edit was clobbered by an unchanged source"
  fi

  echo '{"model":"opus","statusLine":true}' > good.json
  seed "$PWD/good.json" > /dev/null
  if grep -q statusLine "$AGENT_DIR/.claude/settings.json"; then
    ok "a changed source wins over the in-VM copy"
  else
    bad "changed source did not re-seed"
  fi

  rm "$AGENT_DIR/.microvm-settings.hash"
  echo '{"handmade":true}' > "$AGENT_DIR/.claude/settings.json"
  seed "$PWD/good.json" > /dev/null
  if grep -q handmade "$AGENT_DIR/.claude/settings.json.pre-seed" \
     && grep -q statusLine "$AGENT_DIR/.claude/settings.json"; then
    ok "a file the seeding never wrote is backed up before replacement"
  else
    bad "unseeded pre-existing file was replaced without a backup"
  fi

  if seed "$PWD/bad.json" 2>/dev/null; then
    bad "malformed JSON was accepted"
  else
    ok "malformed JSON is refused before boot"
  fi

  if seed "$PWD/nonexistent.json" 2>/dev/null; then
    bad "a missing source file was accepted"
  else
    ok "a missing source file is refused"
  fi

  if ( set -euo pipefail; . ./seed.sh ); then
    ok "unset AGENT_SETTINGS is a no-op"
  else
    bad "unset AGENT_SETTINGS broke the runner"
  fi

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
