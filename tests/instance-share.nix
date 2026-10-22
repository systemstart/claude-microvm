# The per-launch instance dir and its read-only guest share
# (options.claude-vm.instance in modules/base.nix). What a launch hands its
# guest — the env file, EXTRA_CA_CERTS, the nix DB snapshot — and what it keeps
# for itself — its sockets, lock and metadata — live in one directory of its
# own under the runtime dir, of which only guest/ is exported, read-only; it
# goes when the launch does. Agent home, where the guest's files used to be, is
# shared by every launch on a project and writable from each guest.
#
#   - the evaluated guest mounts the share read-only at instance.dir, and
#     everything that reads these files — its own services, the agent's shell,
#     microvm-policy — reads them there, after the mount, and nowhere else;
#   - the built launcher, run for real with systemd-run, systemctl and QEMU
#     stubbed: the instance dir is $XDG_RUNTIME_DIR/claude-microvm/vms/<id>,
#     sticky and owner-only; the guest's files land in its guest/ — the only
#     part exported, by a --readonly virtiofsd QEMU is pointed at — and not in
#     agent home; every socket, QMP's included, is inside it and nothing is
#     written to the working directory; its lock is held and instance.json
#     describes it; two concurrent launches on one agent home keep their own;
#     and it is gone after a normal exit, a failed VM, and a refusal before the
#     VM starts. A missing runtime dir, or one too long for a socket path, is
#     refused before any daemon starts.
#
# What this cannot show is virtiofsd's --readonly holding against a guest: that
# needs a guest kernel on the other end of the socket. The flag is checked on
# the daemon the launcher actually starts.
{ pkgs, lib, runner, config }:

let
  inherit (config.claude-vm) instance;
  envFile = "${instance.dir}/env";
  services = config.systemd.services;

  share = lib.findFirst (s: s.tag == "instance") null config.microvm.shares;
  mountOpts = config.fileSystems.${instance.dir}.options or [ ];
  # The last of these decides; `defaults` means rw.
  lastRw = lib.last ([ "rw" ] ++ lib.filter (o: lib.elem o [ "ro" "rw" "defaults" ]) mountOpts);

  oldPaths = [ "/home/agent/.microvm-env" "/home/agent/.microvm-ca-certs" "/home/agent/.microvm-nix-db.sqlite" "~/.microvm-env" ];
  texts = lib.mapAttrsToList (n: s: { name = "unit ${n}"; text = (s.script or "") + (s.preStart or ""); }) services
    ++ [ { name = "the agent's shell"; text = config.programs.bash.interactiveShellInit; } ];
  stale = lib.filter (t: lib.any (p: lib.hasInfix p t.text) oldPaths) texts;
  readers = lib.filterAttrs (_: s: lib.hasInfix instance.dir (s.script or "")) services;
  # Ordered after the mount either way systemd allows: After= on its unit, or
  # RequiresMountsFor= on a path under it (microvm-policy's egress-proxy-env).
  ordered = s: lib.elem instance.mountUnit (s.after or [ ])
    || lib.any (p: p == instance.dir || lib.hasPrefix "${instance.dir}/" p)
         (lib.toList (s.unitConfig.RequiresMountsFor or [ ]));
  unordered = lib.filterAttrs (_: s: !ordered s) readers;

  structural = [
    {
      name = "the guest has an instance share at ${instance.dir}, virtiofs, readOnly";
      ok = share != null && share.proto == "virtiofs" && share.mountPoint == instance.dir && share.readOnly;
    }
    {
      name = "it is mounted ro (after `defaults`, which would make it rw)";
      ok = lastRw == "ro";
    }
    {
      name = "the agent's shell sources ${envFile}";
      ok = lib.hasInfix "source ${envFile}" config.programs.bash.interactiveShellInit;
    }
    {
      name = "the CA and nix DB imports read the share";
      ok = lib.hasInfix "${instance.dir}/ca-certs" services.microvm-ca-certs.script
        && lib.hasInfix "${instance.dir}/nix-db.sqlite" services.microvm-import-nix-db.script;
    }
    {
      name = "microvm-policy's state file is ${envFile}, after ${instance.mountUnit}";
      ok = config.microvmPolicy.stateFile == envFile && config.microvmPolicy.stateAfter == [ instance.mountUnit ];
    }
    {
      name = "nothing reads the old agent-home copies${lib.optionalString (stale != [ ]) " (still: ${lib.concatMapStringsSep ", " (t: t.name) stale})"}";
      ok = stale == [ ];
    }
    {
      name = "every unit that reads the share is ordered after its mount (${lib.concatStringsSep ", " (lib.attrNames readers)})${lib.optionalString (unordered != { }) " — not: ${lib.concatStringsSep ", " (lib.attrNames unordered)}"}";
      ok = readers != { } && unordered == { };
    }
  ];

  # The built launcher, with what touches the host's systemd and the VM itself
  # swapped for stubs. Matched by pattern rather than by store path, so the test
  # does not depend on which systemd the launcher was built against. Laid out
  # as the package is, with microvm-stop beside it.
  launcher = pkgs.runCommand "microvm-run-stubbed" { } ''
    mkdir -p $out/bin
    ln -s ${runner}/bin/microvm-stop $out/bin/microvm-stop
    sed -E \
      -e 's|/nix/store/[^/ ]*-systemd-[^/ ]*/bin/systemd-run|"$STUBS/systemd-run"|g' \
      -e 's|/nix/store/[^/ ]*-systemd-[^/ ]*/bin/systemctl|"$STUBS/systemctl"|g' \
      -e 's|^( *)bash <\(|\1"$STUBS/qemu" <(|' \
      -e 's|/nix/var/nix/db/db\.sqlite|"$HOST_DB"|g' \
      ${runner}/bin/microvm-run > $out/bin/microvm-run
    grep -q '"$STUBS/qemu" <(' $out/bin/microvm-run || { echo "the QEMU invocation moved; update the stub pattern" >&2; exit 1; }
    grep -q '"$STUBS/systemd-run"' $out/bin/microvm-run || { echo "no systemd-run to stub" >&2; exit 1; }
    chmod +x $out/bin/microvm-run
  '';
in
pkgs.runCommand "instance-share" { nativeBuildInputs = [ pkgs.socat pkgs.sqlite pkgs.jq ]; } ''
  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  ${lib.concatMapStrings (c: if c.ok then ''ok ${lib.escapeShellArg c.name}
  '' else ''bad ${lib.escapeShellArg c.name}
  '') structural}

  # --- stubs ------------------------------------------------------------------
  export STUBS=$TMPDIR/stubs; mkdir -p $STUBS
  # systemd-run: record the daemon's arguments, and stand in for it with a
  # listener on its --socket-path, which is all the launcher waits for.
  # Its own options go to <unit>.opts. With --scope it does what systemd-run
  # does: runs the command in this same process.
  cat > $STUBS/systemd-run <<'EOF'
  #!${pkgs.bash}/bin/bash
  unit= scope= opts=()
  while [ $# -gt 0 ]; do
    case "$1" in --unit=*) unit="''${1#--unit=}" ;; --scope) scope=1 ;; --) shift; break ;; esac
    opts+=("$1"); shift
  done
  if [ -n "$scope" ] && [ -n "''${STUB_NO_SCOPE:-}" ]; then
    echo "Failed to start transient scope unit: Access denied" >&2; exit 1
  fi
  printf '%s\n' "''${opts[@]}" > "$LOG/$unit.opts"
  [ -n "$scope" ] && exec "$@"
  printf '%s\n' "$@" > "$LOG/$unit.args"
  for a in "$@"; do case "$a" in --socket-path=*) sock="''${a#--socket-path=}" ;; esac; done
  ${pkgs.socat}/bin/socat UNIX-LISTEN:"$sock",fork /dev/null &
  echo $! > "$LOG/$unit.pid"
  EOF
  cat > $STUBS/systemctl <<'EOF'
  #!${pkgs.bash}/bin/bash
  [ "$2" = stop ] || exit 0
  echo "$3" >> "$LOG/stopped"
  [ -f "$LOG/$3.pid" ] && kill "$(cat "$LOG/$3.pid")" 2>/dev/null
  exit 0
  EOF
  # qemu: given the rewritten QEMU script, record it and what the guest would
  # find on its share — at boot, and again on the way out, so a launch that
  # overlaps another shows whether its files were touched meanwhile — and the
  # instance dir around it while the launch is live.
  cat > $STUBS/qemu <<'EOF'
  #!${pkgs.bash}/bin/bash
  cat "$1" > "$LOG/qemu.sh"
  dir=$(sed -n 's/^--shared-dir=//p' "$LOG"/*-guest.args)
  echo "$dir" > "$LOG/exported"
  cp -a "$dir" "$LOG/boot"
  inst=$(dirname "$dir")
  stat -c %a "$inst" > "$LOG/instance-mode"
  ( cd "$inst" && stat -c '%n %a' instance.json lock ) > "$LOG/modes"
  ls -A "$inst" > "$LOG/instance-ls"
  cp "$inst/instance.json" "$LOG/instance.json"
  # A new open of the lock file is a new lock: it must find this launch's held.
  if ${pkgs.util-linux}/bin/flock -n "$inst/lock" true; then echo free; else echo held; fi > "$LOG/lock"
  touch "$LOG/started"
  if [ -n "''${HOLD:-}" ]; then
    for _ in $(seq 1 300); do [ -e "$HOLD" ] && break; sleep 0.1; done
  fi
  cp -a "$dir" "$LOG/exit"
  exit "''${QEMU_RC:-0}"
  EOF
  chmod +x $STUBS/*

  export AGENT_HOME=$TMPDIR/agent XDG_RUNTIME_DIR=$TMPDIR/rt HOME=$TMPDIR/home WORK_DIR=$TMPDIR/w NO_PAUSE=1
  mkdir -p $AGENT_HOME $XDG_RUNTIME_DIR $HOME $WORK_DIR $TMPDIR/cwd
  ROOT=$XDG_RUNTIME_DIR/claude-microvm
  export HOST_DB=$TMPDIR/host-db.sqlite
  sqlite3 $HOST_DB "CREATE TABLE ValidPaths (path TEXT); INSERT INTO ValidPaths VALUES ('/nix/store/fixture');"
  printf -- '-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n' > $TMPDIR/fixture.pem

  launch () { # name, then env assignments; the launcher's exit status is $name/rc
    export LOG=$TMPDIR/$1; mkdir -p $LOG; shift
    # From a directory of its own, to show the launcher writes nothing there.
    # `|| rc=$?`, not `; rc=$?`: the build shell runs with -e.
    rc=0; (cd $TMPDIR/cwd && exec env "$@" ${launcher}/bin/microvm-run) </dev/null >$LOG/out 2>&1 || rc=$?; echo $rc > $LOG/rc
  }
  sockets_left () { find $XDG_RUNTIME_DIR -name '*.sock*' | wc -l; }
  # No launch dirs, sockets or old-style dirs left. The root and vms/ stay,
  # empty: removing them on exit would race a launch starting meanwhile.
  gone () { [ "$(ls -A $ROOT 2>/dev/null)" = vms ] && [ -z "$(ls -A $ROOT/vms)" ] \
              && [ ! -e $AGENT_HOME-instance ] && [ "$(sockets_left)" = 0 ]; }
  left () { ls -R $ROOT $AGENT_HOME-instance 2>/dev/null | head -20; }

  # --- one launch ---------------------------------------------------------------
  # Left by an earlier launcher; the env file had API keys in it.
  echo 'ANTHROPIC_API_KEY=stale-key' > $AGENT_HOME/.microvm-env
  mkdir $AGENT_HOME/.microvm-ca-certs; touch $AGENT_HOME/.microvm-nix-db.sqlite

  launch one EXTRA_ENV=WHO=one EXTRA_CA_CERTS=$TMPDIR/fixture.pem ANTHROPIC_API_KEY=sk-test
  # G is what the guest virtiofsd exports; D, the instance dir around it.
  L=$TMPDIR/one; G=$(cat $L/exported 2>/dev/null); D=$(dirname "$G")
  if [ "$(cat $L/rc)" = 0 ] && [ -e $L/started ]; then ok "a launch runs to the VM and exits cleanly"
  else bad "the launch did not reach the VM (rc $(cat $L/rc))"; cat $L/out >&2; fi
  if [ "$G" = "$ROOT/vms/$(jq -r .id $L/instance.json 2>/dev/null)/guest" ]; then
    ok "the instance dir is \$XDG_RUNTIME_DIR/claude-microvm/vms/<id>, and only its guest/ is exported"
  else bad "exported '$G', not $ROOT/vms/<id>/guest"; fi
  [ "$(cat $L/instance-mode)" = 1700 ] && ok "the instance dir is owner-only and sticky" || bad "instance dir is $(cat $L/instance-mode)"
  [ "$(stat -c %a $L/boot)" = 1500 ] && ok "guest/ is owner-only, read-only and sticky" || bad "guest/ is $(stat -c %a $L/boot)"
  grep -qx 'WHO=one' $L/boot/env && grep -qx 'ANTHROPIC_API_KEY=sk-test' $L/boot/env \
    && ok "the guest finds this launch's env on the share" || { bad "env not on the share"; cat $L/boot/env >&2; }
  [ "$(stat -c %a $L/boot/env)" = 1400 ] && ok "the env file is 0400, and sticky" || bad "env file is $(stat -c %a $L/boot/env)"
  # Finished files are read-only against accidental edits, and instance.json
  # is put in place whole.
  ro=$(cd $L/boot && find . -mindepth 1 \( -type d ! -perm 1500 -o -type f ! -perm 1400 \) -printf '%p %m\n')
  if [ -z "$ro" ] && [ "$(cat $L/modes)" = $'instance.json 1400\nlock 1400' ] && ! grep -q '\.new$' $L/instance-ls; then
    ok "everything in guest/, instance.json and lock are read-only (files 0400, dirs 0500); no half-written instance.json"
  else bad "not read-only: [$ro] [$(cat $L/modes)] [$(cat $L/instance-ls)]"; fi
  [ -f $L/boot/ca-certs/fixture.pem ] && ok "EXTRA_CA_CERTS lands on the share" || bad "no ca-certs on the share"
  [ "$(sqlite3 $L/boot/nix-db.sqlite 'SELECT path FROM ValidPaths')" = /nix/store/fixture ] \
    && ok "the nix DB snapshot lands on the share" || bad "no nix DB snapshot on the share"
  if [ ! -e $AGENT_HOME/.microvm-env ] && [ ! -e $AGENT_HOME/.microvm-ca-certs ] && [ ! -e $AGENT_HOME/.microvm-nix-db.sqlite ] && [ ! -e $AGENT_HOME-instance ]; then
    ok "agent home keeps none of them, and the stale copies (API key included) are gone"
  else bad "agent home still has: $(ls -A $AGENT_HOME)"; fi

  A=$(ls $L/*-guest.args 2>/dev/null)
  if [ -n "$A" ] && grep -qx -- '--readonly' $A && grep -qx -- "--shared-dir=$G" $A; then
    ok "guest/ is served by its own virtiofsd, --readonly"
  else bad "no --readonly virtiofsd serving $G"; cat $A >&2 2>/dev/null || true; fi
  grep -qx -- '--translate-uid' $A && grep -qx -- 'map:1000:0:1' $A \
    && ok "...which shows the files as the agent's" || bad "guest-share virtiofsd does not translate uids"
  H=$(ls $L/*-agent-home.args)
  grep -qx -- "--shared-dir=$AGENT_HOME" $H && ! grep -q -- "^--shared-dir=$D" $H \
    && ok "agent home's virtiofsd does not export the instance dir" || bad "agent-home virtiofsd args unexpected"
  S=$(sed -n 's/^--socket-path=//p' $A)
  if grep -qF "path=$S" $L/qemu.sh && ! grep -q 'virtiofs-instance\.sock' <(sed "s|$S||g" $L/qemu.sh); then
    ok "QEMU's guest-share device is pointed at that daemon's socket"
  else bad "QEMU is not pointed at $S"; grep -o 'chardev [^ ]*' $L/qemu.sh >&2 || true; fi

  outside=$(sed -n 's/^--socket-path=//p' $L/*.args | grep -v "^$D/" || true)
  [ "$(sed -n 's/^--socket-path=//p' $L/*.args | wc -l)" = 3 ] && [ -z "$outside" ] \
    && ok "all three virtiofsd sockets are in the instance dir" || bad "virtiofsd sockets outside it: $outside"
  if grep -qF -- "-qmp unix:$D/qmp.sock," $L/qemu.sh && ! grep -qE '(^|[ :])claude-vm\.sock' $L/qemu.sh; then
    ok "QEMU's QMP socket is the instance dir's qmp.sock, not a relative claude-vm.sock"
  else bad "QMP socket not rewritten: $(grep -o -- '-qmp [^ ]*' $L/qemu.sh)"; fi
  [ -z "$(ls -A $TMPDIR/cwd)" ] && ok "nothing is written to the working directory" || bad "written to the working directory: $(ls -A $TMPDIR/cwd)"
  [ "$(cat $L/lock)" = held ] && ok "the launch holds its instance dir's lock while it runs" || bad "the lock was free during the launch"
  J=$L/instance.json
  if [ "$(jq -r .version $J)" = 1 ] && [ "$(jq -r '.pid | type' $J)" = number ] && [ "$(jq -r .flavor $J)" = claude ] \
     && [ "$(jq -r .work $J)" = $WORK_DIR ] && [ "$(jq -r .agentHome $J)" = $AGENT_HOME ] && [ "$(jq -r .guest $J)" = "$G" ] \
     && [ "$(jq -r .guestMount $J)" = /run/microvm ] && [ "$(jq -r .sockets.qmp $J)" = "$D/qmp.sock" ] \
     && [ "$(jq -r .sockets.guest $J)" = "$S" ]; then
    ok "instance.json describes the launch: pid, flavor, work, agent home, guest dir and mount, sockets"
  else bad "instance.json is off:"; cat $J >&2; fi
  # The units it names are the ones the launcher started (the stub records each
  # under its unit name), and no egress unit runs under the default policy.
  started=$(cd $L && ls *.opts | sed 's/\.opts$//' | sort)
  named=$(jq -r '.units | to_entries[] | select(.value != null) | .value' $J | sort)
  if [ "$started" = "$named" ] && [ "$(jq -r .units.egress $J)" = null ] && [ "$(jq -r .egressPolicy $J)" = open ] \
     && [ "$(jq -r .units.guest $J)" = "$(basename $A .args)" ]; then
    ok "instance.json names exactly the units the launch started; egress is null under EGRESS_POLICY=open"
  else bad "instance.json units: named [$named], started [$started]"; fi

  # The launch's units: one stem, claude_microvm-<id>, in a slice of their own
  # nested in claude_microvm.slice. The launcher re-ran itself in the scope,
  # and every daemon is in the slice, bound to the scope, tagged with the
  # launch's ID, and described.
  SC=$(jq -r .units.scope $J); LID=$(jq -r .id $J); SL=claude_microvm-$LID.slice
  if [ "$SC" = "claude_microvm-$LID.scope" ] && [ "$(jq -r .slice $J)" = $SL ] && [ "$D" = "$ROOT/vms/$LID" ] \
     && grep -qx -- --scope $L/$SC.opts && grep -qx -- --slice=$SL $L/$SC.opts \
     && grep -qx -- "--description=claude microvm $LID: the VM, for $WORK_DIR" $L/$SC.opts; then
    ok "the launcher runs in its own scope, $SC, in its own slice, $SL, under the instance dir's ID"
  else bad "no launch scope: scope '$SC', slice '$(jq -r .slice $J)', id '$LID', dir $D"; cat $L/$SC.opts >&2 2>/dev/null || true; fi
  names=$(jq -r '[.units.work, .units.agentHome, .units.guest] | join(" ")' $J)
  [ "$names" = "claude_microvm-$LID-work claude_microvm-$LID-agent-home claude_microvm-$LID-guest" ] \
    && ok "the daemons are named claude_microvm-<id>-{work,agent-home,guest}" || bad "daemon names: $names"
  props_ok=1
  for u in $(jq -r '.units | to_entries[] | select(.key != "scope" and .value != null) | .value' $J); do
    for want in --slice=$SL "BindsTo=$SC" "After=$SC" "LogExtraFields=MICROVM_ID=$LID"; do
      grep -qx -- "$want" $L/$u.opts || { props_ok=0; echo "  $u lacks $want" >&2; }
    done
    grep -qE -- "^--description=claude microvm $LID: .+, for $WORK_DIR$" $L/$u.opts || { props_ok=0; echo "  $u lacks a description" >&2; }
  done
  [ $props_ok = 1 ] && ok "every daemon is in the launch's slice, bound to its scope (BindsTo= + After=), tagged MICROVM_ID, and described" \
    || bad "daemons are not all in the launch's slice and bound to its scope"

  # The session contract lists the guest share beside the other two, as it
  # actually is for this launch, and gives the launch's handle and how to stop it.
  if grep -qF "guest share ● this launch only → /run/microvm, read-only to the guest" $L/out \
     && grep -qF "env, CA certs, nix DB snapshot; removed when the launch ends" $L/out; then
    ok "the contract lists the guest share, read-only and per-launch, with what this launch put in it"
  else bad "contract has no guest-share row, or the wrong contents:"; sed -n '/session contract/,$p' $L/out >&2; fi
  if grep -qF "$LID · $XDG_RUNTIME_DIR/claude-microvm/vms/$LID/" $L/out \
     && grep -qxF "                stop: ${launcher}/bin/microvm-stop $LID" $L/out; then
    ok "the contract gives the launch ID, where its files are, and microvm-stop, from beside the launcher, to stop it"
  else bad "contract has no launch row naming $LID and microvm-stop"; sed -n '/session contract/,$p' $L/out >&2; fi

  # Where no scope can be had, the launch still runs — unbound, and saying so.
  launch unscoped STUB_NO_SCOPE=1
  U=$TMPDIR/unscoped; UJ=$U/instance.json; USL=claude_microvm-$(jq -r .id $UJ 2>/dev/null).slice
  if [ "$(cat $U/rc)" = 0 ] && [ -e $U/started ] && grep -q 'cannot run this launch in a systemd --user scope' $U/out \
     && [ "$(jq -r .units.scope $UJ)" = null ] && [ -z "$(find $U -name '*.scope.opts')" ]; then
    ok "without a scope to be had, the launch still runs, warns, and records no scope"
  else bad "unscoped launch: rc $(cat $U/rc)"; cat $U/out >&2; fi
  # Stopping its slice would stop only its daemons and leave the VM running on
  # shares that have gone, so its contract says microvm-stop, never that.
  if grep -qxF "                stop: ${launcher}/bin/microvm-stop $(jq -r .id $UJ)" $U/out && ! grep -q 'systemctl --user stop' $U/out; then
    ok "...and its contract says to stop it with microvm-stop, not by stopping its slice"
  else bad "unscoped launch's stop hint:"; grep -A1 '^  launch' $U/out >&2; fi
  if ! grep -q '^BindsTo=\|^After=' $U/*.opts && grep -qx -- --slice=$USL $(ls $U/*-guest.opts); then
    ok "...and its daemons start unbound (BindsTo= a missing scope would stop them starting), still in their slice"
  else bad "unscoped launch's daemons are bound to a scope that does not exist, or not in $USL"; fi
  gone || bad "unscoped launch left: $(left)"

  gone && ok "on exit the instance dir goes and no sockets are left; the shared root and vms/ stay, empty" || bad "left behind: $(left)"
  grep -qx "$(basename $A .args)" $L/stopped && ok "on exit the guest-share virtiofsd is stopped" || bad "guest-share virtiofsd not stopped"

  # --- two at once, one agent home ------------------------------------------------
  HOLD=$TMPDIR/release
  launch first EXTRA_ENV=WHO=first HOLD=$HOLD &
  for _ in $(seq 1 300); do [ -e $TMPDIR/first/started ] && break; sleep 0.1; done
  launch second EXTRA_ENV=WHO=second HOLD=$HOLD &
  for _ in $(seq 1 300); do [ -e $TMPDIR/second/started ] && break; sleep 0.1; done
  if [ -e $TMPDIR/first/started ] && [ -e $TMPDIR/second/started ]; then
    [ "$(ls $ROOT/vms | wc -l)" = 2 ] && ok "two concurrent launches have two instance dirs" \
      || bad "concurrent launches share instance dirs: $(ls $ROOT/vms)"
  else bad "the two launches did not overlap"; cat $TMPDIR/first/out $TMPDIR/second/out >&2; fi
  touch $HOLD; wait
  grep -qx 'WHO=first' $TMPDIR/first/exit/env && ! grep -q 'WHO=second' $TMPDIR/first/exit/env \
    && ok "the second launch leaves the first one's env alone" || { bad "the first launch's env changed under it"; cat $TMPDIR/first/exit/env >&2; }
  grep -qx 'WHO=second' $TMPDIR/second/boot/env && ok "the second launch boots with its own env" || bad "second launch has the wrong env"
  # No EXTRA_CA_CERTS here, so the contract must not claim any.
  grep -qF "env, nix DB snapshot; removed when the launch ends" $TMPDIR/second/out \
    && ok "...and its contract lists only what its guest share holds (no CA certs)" \
    || { bad "second launch's guest-share row is wrong:"; grep -A1 'guest share' $TMPDIR/second/out >&2; }
  q1=$(grep -o -- '-qmp unix:[^,]*' $TMPDIR/first/qemu.sh); q2=$(grep -o -- '-qmp unix:[^,]*' $TMPDIR/second/qemu.sh)
  [ -n "$q1" ] && [ "$q1" != "$q2" ] && ok "...and its own QMP socket" || bad "concurrent launches share a QMP socket: $q1"
  gone && ok "after both exit, nothing is left" || bad "left after both: $(left)"

  # --- the longest default paths ---------------------------------------------------
  # A 12-character project name, the most WORK_BASENAME keeps, under a runtime
  # dir as long as /run/user/<7-digit uid>. With a UUID for the launch ID and
  # virtiofs-* socket names, a 4-digit uid was already past the limit.
  RT=$TMPDIR/r; while [ "''${#RT}" -lt 17 ]; do RT="$RT"x; done
  mkdir -p $RT $TMPDIR/longprojectname
  launch longest XDG_RUNTIME_DIR=$RT WORK_DIR=$TMPDIR/longprojectname
  LJ=$TMPDIR/longest/instance.json
  # `|| true`: a refused launch writes no instance.json, and the build shell
  # runs with -e and pipefail — that must be a FAIL below, not a crash here.
  longest=$({ jq -r '.sockets[]' $LJ 2>/dev/null || true; } | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
  if [ "$(cat $TMPDIR/longest/rc)" = 0 ] && [ -e $TMPDIR/longest/started ] && [ "$longest" -le 107 ] \
     && [ "$(jq -r .vmId $LJ)" = longprojectn-claude-vm ]; then
    ok "a 12-character project under a 7-digit uid's runtime dir launches: longest socket path $longest bytes, of 107"
  else bad "longest default paths: rc $(cat $TMPDIR/longest/rc), longest socket $longest"; cat $TMPDIR/longest/out >&2; fi
  [[ "$(jq -r .id $LJ)" =~ ^[0-9a-f]{12}$ ]] && ok "the launch ID is 12 hex digits" || bad "launch ID is '$(jq -r .id $LJ)'"
  [ -z "$(ls -A $RT/claude-microvm/vms 2>/dev/null)" ] || bad "longest-path launch left: $(ls -R $RT)"

  # --- failure paths ----------------------------------------------------------------
  launch crash QEMU_RC=3
  [ "$(cat $TMPDIR/crash/rc)" = 3 ] && gone \
    && ok "a VM that fails still has its instance dir removed" || bad "after a failed VM: rc $(cat $TMPDIR/crash/rc), $(left)"
  echo '{broken' > $TMPDIR/bad.json
  launch refused AGENT_SETTINGS=$TMPDIR/bad.json
  if [ "$(cat $TMPDIR/refused/rc)" != 0 ] && [ ! -e $TMPDIR/refused/started ] && gone; then
    ok "a launch refused before the VM starts removes its instance dir"
  else bad "after a refusal: rc $(cat $TMPDIR/refused/rc), $(left)"; fi

  launch noruntime XDG_RUNTIME_DIR=$TMPDIR/absent
  if [ "$(cat $TMPDIR/noruntime/rc)" != 0 ] && grep -q 'no runtime directory' $TMPDIR/noruntime/out && [ -z "$(find $TMPDIR/noruntime -name "*.args")" ]; then
    ok "a missing runtime dir is refused, before any daemon starts"
  else bad "missing runtime dir: rc $(cat $TMPDIR/noruntime/rc), in its log: $(ls $TMPDIR/noruntime)"; cat $TMPDIR/noruntime/out >&2; fi
  LONG=$TMPDIR/$(printf 'r%.0s' $(seq 1 60)); mkdir -p $LONG
  launch longruntime XDG_RUNTIME_DIR=$LONG
  if [ "$(cat $TMPDIR/longruntime/rc)" != 0 ] && grep -q 'socket path too long' $TMPDIR/longruntime/out \
     && [ -z "$(find $TMPDIR/longruntime -name "*.args")" ] && [ -z "$(ls -A $LONG)" ]; then
    ok "a runtime dir too long for a socket path is refused, before any daemon starts, leaving nothing"
  else bad "long runtime dir: rc $(cat $TMPDIR/longruntime/rc), left $(ls -A $LONG)"; cat $TMPDIR/longruntime/out >&2; fi

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
