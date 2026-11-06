# Test for AGENT_HOME_MODE=ephemeral (README "Home directory persistence"),
# with the built launcher run for real, systemd and QEMU stubbed
# (tests/lib/stubbed-launcher.nix):
#
#   - the agent-home share is a fresh $XDG_DATA_HOME/<flavor dir>/.ephemeral/<id>/home,
#     under the launch's own ID, and the CRI and store images' dirs are inside
#     that per-launch dir rather than beside the project's home;
#   - on exit all of it goes, read-only directories the guest left included,
#     and the project's own home is never created;
#   - its egress logs still go beside the project's home, and stay;
#   - the contract and instance.json say which mode the launch ran in;
#   - a launch sweeps what killed launchers left: dirs whose launch ID holds
#     no instance lock, and only those;
#   - it refuses AGENT_HOME, and DIRENV_ALLOW=1, before any daemon starts;
#   - the default, persistent, is what it was.
{ pkgs, lib, runner }:

let
  harness = import ./lib/stubbed-launcher.nix { inherit pkgs runner; };
in
pkgs.runCommand "agent-home-ephemeral" { nativeBuildInputs = [ pkgs.socat pkgs.sqlite pkgs.jq pkgs.util-linux ]; } ''
  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  ${harness.preamble}

  export XDG_DATA_HOME=$TMPDIR/data XDG_RUNTIME_DIR=$TMPDIR/rt HOME=$TMPDIR/home WORK_DIR=$TMPDIR/proj NO_PAUSE=1
  unset AGENT_HOME
  mkdir -p $XDG_DATA_HOME $XDG_RUNTIME_DIR $HOME $WORK_DIR
  export HOST_DB=$TMPDIR/host-db.sqlite
  sqlite3 $HOST_DB "CREATE TABLE ValidPaths (path TEXT);"
  DATA=$XDG_DATA_HOME/claude-microvm
  EPH=$DATA/.ephemeral
  PROJECT=$DATA/proj-$(echo -n "$(realpath $WORK_DIR)" | sha256sum | cut -c1-12)
  home_of () { sed -n 's/^--shared-dir=//p' "$TMPDIR/$1"/*-agent-home.args; }

  # --- what killed launchers left, for the sweep ---------------------------------
  mkdir -p $EPH/aaaaaaaaaaaa/home/.cache/ro $EPH/bbbbbbbbbbbb/home $EPH/keep-me
  chmod 555 $EPH/aaaaaaaaaaaa/home/.cache/ro
  # A launch still running: its home is locked, as the launcher locks its
  # own — by this shell, on a descriptor of its own, not by a background
  # process, which would keep the build log open after the test ends.
  exec {held}<$EPH/bbbbbbbbbbbb
  flock -n $held
  # A symlink under a launch-ID name, to a tree the sweep must not touch.
  mkdir -p $TMPDIR/victim/sub; chmod 555 $TMPDIR/victim/sub
  ln -s $TMPDIR/victim $EPH/cccccccccccc
  # Killed between mkdir and rename: an old .new goes, a fresh one may be a
  # launch about to lock it.
  mkdir -p $EPH/dddddddddddd.new $EPH/eeeeeeeeeeee.new
  touch -d "20 minutes ago" $EPH/dddddddddddd.new

  # --- one ephemeral launch ---------------------------------------------------------
  HOLD=$TMPDIR/release
  launch eph AGENT_HOME_MODE=ephemeral ENABLE_CRI=docker EGRESS_POLICY=monitor HOLD=$HOLD &
  for _ in $(seq 1 300); do [ -e $TMPDIR/eph/started ] && break; sleep 0.1; done
  E=$TMPDIR/eph; ID=$(jq -r .id $E/instance.json 2>/dev/null || true)
  if [ -e $E/started ] && [ "$(home_of eph)" = "$EPH/$ID/home" ]; then
    ok "the agent-home share is .ephemeral/<launch id>/home"
  else bad "agent home is '$(home_of eph)', not $EPH/$ID/home"; cat $E/out >&2; fi
  [ -d "$EPH/$ID/home-cri" ] && [ ! -e "$PROJECT-cri" ] \
    && ok "the CRI image's dir is inside the launch's dir, not beside the project's home" \
    || bad "CRI dir: $(ls -A $EPH/$ID 2>/dev/null) / $(ls -A $DATA)"
  [ "$(stat -c %a $EPH/$ID)" = 700 ] && ok "the launch's dir is owner-only" || bad "launch dir is $(stat -c %a $EPH/$ID)"
  # What the guest leaves: a read-only directory, as Go's module cache is.
  mkdir -p "$EPH/$ID/home/go/pkg/mod/x"; chmod -R a-w "$EPH/$ID/home/go"
  [ ! -e $EPH/aaaaaaaaaaaa ] && ok "a dead launch's dir is swept, read-only contents and all" || bad "dead launch's dir was not swept"
  [ -d $EPH/bbbbbbbbbbbb ] && ok "a live launch's dir is left alone" || bad "a live launch's dir was swept"
  [ -d $EPH/keep-me ] && ok "a dir that is not named by a launch ID is left alone" || bad "keep-me was swept"
  [ ! -e $EPH/dddddddddddd.new ] && [ -d $EPH/eeeeeeeeeeee.new ] \
    && ok "an abandoned <id>.new is swept once it is ten minutes old, a fresh one is not" \
    || bad ".new sweep: $(ls -A $EPH)"
  [ -L $EPH/cccccccccccc ] && [ "$(stat -c %a $TMPDIR/victim/sub)" = 555 ] \
    && ok "a symlink is neither followed nor removed" || bad "the sweep followed or removed a symlink: $(stat -c %a $TMPDIR/victim/sub)"
  # A second launch on the same data dir but its own runtime dir, so it
  # cannot see the first one's instance lock: its sweep must still leave the
  # first one's home, which it knows is live by the home's own lock.
  mkdir -p $TMPDIR/rt2
  launch other AGENT_HOME_MODE=ephemeral XDG_RUNTIME_DIR=$TMPDIR/rt2
  if [ "$(cat $TMPDIR/other/rc)" = 0 ] && [ -d "$EPH/$ID/home" ]; then
    ok "a launch with another runtime dir leaves a running launch's home alone"
  else bad "the other launch (rc $(cat $TMPDIR/other/rc)) swept the running launch's home"; cat $TMPDIR/other/out >&2; fi
  touch $HOLD; wait
  exec {held}>&-

  if [ "$(cat $E/rc)" = 0 ] && [ ! -e "$EPH/$ID" ]; then
    ok "on exit the launch's agent home goes, read-only dirs included, CRI and store dirs with it"
  else bad "after exit: rc $(cat $E/rc), left $(ls -A $EPH/$ID 2>/dev/null)"; cat $E/out >&2; fi
  [ ! -e "$PROJECT" ] && ok "the project's own agent home is never created" || bad "$PROJECT was created"
  [ -d "$PROJECT-egress" ] && [ -n "$(ls -A $PROJECT-egress)" ] \
    && ok "its egress logs are beside the project's home, and stay" || bad "no egress logs in $PROJECT-egress: $(ls -A $DATA)"
  grep -q 'this launch only: removed when it ends' $E/out && grep -qF "egress logs kept in" $E/out \
    && ok "the contract says the agent home is this launch's only, and where the egress logs stay" \
    || { bad "contract agent-home row:"; grep -A2 'agent home' $E/out >&2; }
  [ "$(jq -r .agentHomeMode $E/instance.json)" = ephemeral ] && ok "instance.json says agentHomeMode: ephemeral" || bad "instance.json agentHomeMode: $(jq -r .agentHomeMode $E/instance.json)"

  # --- refusals, before any daemon ---------------------------------------------------
  refused () { # name message, then env
    n=$1 msg=$2; shift 2
    launch "$n" "$@"
    if [ "$(cat $TMPDIR/$n/rc)" != 0 ] && grep -q "$msg" $TMPDIR/$n/out && [ -z "$(find $TMPDIR/$n -name '*.args')" ]; then
      ok "refused before any daemon: $*"
    else bad "not refused as expected: $* (rc $(cat $TMPDIR/$n/rc))"; cat $TMPDIR/$n/out >&2; fi
  }
  refused with-home "unset AGENT_HOME" AGENT_HOME_MODE=ephemeral AGENT_HOME=$TMPDIR/elsewhere
  refused with-direnv "DIRENV_ALLOW=1 cannot be combined" AGENT_HOME_MODE=ephemeral DIRENV_ALLOW=1
  refused bogus "AGENT_HOME_MODE must be persistent or ephemeral" AGENT_HOME_MODE=temp
  # The launcher's state inside the work share is the guest's to write.
  refused inside-work "is inside WORK_DIR" AGENT_HOME_MODE=ephemeral WORK_DIR=$TMPDIR
  refused root-work "/[^ ]* is inside WORK_DIR=/," AGENT_HOME_MODE=ephemeral WORK_DIR=/
  # The other way round: a work share that is the .ephemeral dir, or one
  # launch's home, would show the guest every home there.
  refused work-is-ephemeral "WORK_DIR=$EPH is inside $DATA" AGENT_HOME_MODE=ephemeral WORK_DIR=$EPH
  mkdir -p $EPH/ffffffffffff/home
  refused work-in-a-home "WORK_DIR=$EPH/ffffffffffff/home is inside $DATA" AGENT_HOME_MODE=ephemeral WORK_DIR=$EPH/ffffffffffff/home
  launch inside-work-persistent WORK_DIR=$TMPDIR
  if [ "$(cat $TMPDIR/inside-work-persistent/rc)" = 0 ] && grep -q "is inside WORK_DIR=.*the guest can write this launcher's state" $TMPDIR/inside-work-persistent/out; then
    ok "a persistent launch with its state inside the work share runs, and is warned"
  else bad "persistent launch inside WORK_DIR: rc $(cat $TMPDIR/inside-work-persistent/rc)"; cat $TMPDIR/inside-work-persistent/out >&2; fi
  # An AGENT_HOME beside the project, as in the README, is no overlap.
  mkdir -p $HOME/project
  launch beside AGENT_HOME=$HOME/.my-agent-home WORK_DIR=$HOME/project
  if [ "$(cat $TMPDIR/beside/rc)" = 0 ] && ! grep -q "inside WORK_DIR\|is inside " $TMPDIR/beside/out; then
    ok "AGENT_HOME=~/.my-agent-home with a project in ~ is not taken for an overlap"
  else bad "AGENT_HOME beside the project was flagged:"; grep "inside" $TMPDIR/beside/out >&2; fi

  # --- the default --------------------------------------------------------------------
  launch default
  if [ "$(cat $TMPDIR/default/rc)" = 0 ] && [ "$(home_of default)" = "$PROJECT" ] && [ -d "$PROJECT" ] \
     && [ "$(jq -r .agentHomeMode $TMPDIR/default/instance.json)" = persistent ] && grep -q 'persists across sessions' $TMPDIR/default/out; then
    ok "by default the project's agent home is used and kept, as before"
  else bad "default launch: rc $(cat $TMPDIR/default/rc), home '$(home_of default)'"; cat $TMPDIR/default/out >&2; fi

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
