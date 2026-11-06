# The built launcher, run for real with what touches the host's systemd and
# the VM itself swapped for stubs — shared by the tests that drive a whole
# launch without a host: instance-share, agent-home-ephemeral.
#
#   launcher   the runner's microvm-run with systemd-run, systemctl and QEMU
#              replaced by "$STUBS/…" and the host nix DB by "$HOST_DB"
#   preamble   shell for the test's runCommand: writes the stubs to $STUBS
#              and defines `launch <name> [VAR=value…]`, which runs the
#              launcher from an empty $TMPDIR/cwd with its log in
#              $TMPDIR/<name> ($LOG): out, rc, every daemon's <unit>.args /
#              .opts / .pid, `stopped`, and — once QEMU "starts" — qemu.sh,
#              started, boot/ and exit/ (the guest share then and at exit),
#              exported, instance-mode, modes, instance-ls, instance.json,
#              lock. QEMU_RC sets the VM's exit status; HOLD=<file> keeps it
#              running until that file appears, or until it is powered off
#              over QMP when QMP=1 has it answer QMP (commands in qmp,
#              powered-off once off; QMP_IGNORE_POWERDOWN=1 ignores the
#              power button).
{ pkgs, runner }:

rec {
  # Matched by pattern rather than by store path, so the test does not depend
  # on which systemd the launcher was built against. Laid out as the package
  # is, with microvm-stop beside it.
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

  preamble = ''
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
  # QMP=1: answer QMP where the launcher told QEMU to, and "power off" on the
  # power button or quit — the button is ignored with QMP_IGNORE_POWERDOWN=1,
  # as by a guest that does not react to it. Each command goes to $LOG/qmp.
  if [ -n "''${QMP:-}" ]; then
    qmp=$(grep -o -- '-qmp unix:[^,]*' "$LOG/qemu.sh" | head -1); qmp="''${qmp#-qmp unix:}"
    ${pkgs.socat}/bin/socat UNIX-LISTEN:"$qmp",fork EXEC:"$STUBS/qmp" &
    listener=$!
  fi
  touch "$LOG/started"
  if [ -n "''${HOLD:-}" ]; then
    for _ in $(seq 1 300); do [ -e "$HOLD" ] || [ -e "$LOG/powered-off" ] && break; sleep 0.1; done
  fi
  [ -n "''${listener:-}" ] && kill "$listener" 2>/dev/null
  cp -a "$dir" "$LOG/exit"
  exit "''${QEMU_RC:-0}"
  EOF
  cat > $STUBS/qmp <<'EOF'
  #!${pkgs.bash}/bin/bash
  echo '{"QMP": {"version": {}, "capabilities": []}}'
  while IFS= read -r line; do
    echo "$line" >> "$LOG/qmp"
    echo '{"return": {}}'
    case "$line" in
      *system_powerdown*) [ -n "''${QMP_IGNORE_POWERDOWN:-}" ] || touch "$LOG/powered-off" ;;
      *'"quit"'*) touch "$LOG/powered-off" ;;
    esac
  done
  EOF
  chmod +x $STUBS/*

  launch () { # name, then env assignments; the launcher's exit status is $name/rc
    export LOG=$TMPDIR/$1; mkdir -p $LOG $TMPDIR/cwd; shift
    # From a directory of its own, to show the launcher writes nothing there.
    # `|| rc=$?`, not `; rc=$?`: the build shell runs with -e.
    rc=0; (cd $TMPDIR/cwd && exec env "$@" ${launcher}/bin/microvm-run) </dev/null >$LOG/out 2>&1 || rc=$?; echo $rc > $LOG/rc
  }
  '';
}
