# How the agent runs on the VM's console (modules/base.nix,
# programs.bash.interactiveShellInit and programs.bash.logout). The real
# rendered init runs in a login shell on a pseudo-terminal, with ctrl+z typed
# as a key, a stand-in agent, and `sudo` stubbed to note a poweroff:
#
#   - ctrl+z leaves the agent stopped and the shell at a prompt that says so;
#     `fg` resumes it, and the VM powers off when it ends — bash did not come
#     back from a job stopped while its startup files ran, so the console hung
#     for good;
#   - abandoned with `exit` (twice: bash warns of the stopped job once), the VM
#     powers off;
#   - an agent that ends powers the VM off, without the suspend hint;
#   - only the console's own login shell starts the agent and powers off when
#     left: not one on another terminal, nor one below the agent.
{ pkgs, lib, config }:

let
  launch = config.claude-vm.agent.launchCommand;
  rendered = config.programs.bash.interactiveShellInit;
  evalLine = "eval \"${launch} \${AGENTS_ARGS:-}\"";
  consoleTest = "[ \"$(tty 2>/dev/null)\" = /dev/hvc0 ]";
  init = assert lib.hasInfix evalLine rendered; assert lib.hasInfix consoleTest rendered;
    lib.replaceStrings [ evalLine consoleTest ]
      [ "eval \"$FAKE_AGENT\"" "[ \"$(tty 2>/dev/null)\" = \"$TEST_CONSOLE\" ]" ] rendered;
in
pkgs.runCommand "agent-console" {
  nativeBuildInputs = [ pkgs.util-linux pkgs.bashInteractive pkgs.coreutils pkgs.gnugrep pkgs.git ];
} ''
  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  T=$TMPDIR
  mkdir -p $T/bin
  cat > $T/bin/sudo <<EOF
  #!${pkgs.bash}/bin/bash
  echo "\$*" >> \$EVENTS
  EOF
  # The stand-in agent: cooked mode, so the terminal turns ctrl+z into SIGTSTP
  # for its process group, as it does for an agent that suspends itself.
  cat > $T/bin/agent <<EOF
  #!${pkgs.bash}/bin/bash
  echo agent-running >> \$EVENTS
  while [ ! -e \$EVENTS.finish ]; do sleep 0.1; done
  echo agent-done >> \$EVENTS
  EOF
  chmod +x $T/bin/*
  cp ${pkgs.writeText "init.sh" init} $T/init.sh

  # One login shell on a pty, driven by `steps`: "wait <regex>" (on the
  # events, or the terminal's output with out:<regex>), "key <printf>",
  # "finish" (the agent may end).
  run () { # name, console (yes/no), then steps
    local n=$1 console=$2; shift 2
    local h=$T/$n
    mkdir -p $h/home/.claude
    printf '. %s/init.sh && echo init-sourced\n' "$T" > $h/home/.bash_profile
    cp ${pkgs.writeText "logout" config.programs.bash.logout} $h/home/.bash_logout
    : > $h/events
    (
      for s in "$@"; do
        case "$s" in
          wait\ out:*) p=''${s#wait out:}; for _ in $(seq 1 100); do grep -qE "$p" $h/out 2>/dev/null && break; sleep 0.1; done ;;
          wait\ *) p=''${s#wait }; for _ in $(seq 1 100); do grep -qE "$p" $h/events && break; sleep 0.1; done ;;
          key\ *) sleep 0.3; printf "''${s#key }" ;;
          finish) touch $h/events.finish ;;
        esac
      done
      sleep 1
    ) | env -i SHELL=${pkgs.bash}/bin/bash PATH=$T/bin:$PATH HOME=$h/home TERM=dumb EVENTS=$h/events FAKE_AGENT=agent \
          XDG_RUNTIME_DIR=$h ''${EXTRA:+$EXTRA} \
          TEST_CONSOLE=$([ $console = yes ] && echo __pty__ || echo /dev/nonexistent) \
          timeout 30 script -qfec 'case $TEST_CONSOLE in __pty__) export TEST_CONSOLE=$(tty) ;; esac; exec bash --login -i' $h/out >/dev/null 2>&1 || true
    tr -d '\r' < $h/out > $h/out.txt
  }
  events () { uniq $T/$1/events | tr "\n" " " | sed "s/ $//"; }

  # --- ctrl+z, then fg ---------------------------------------------------------------------
  run fg yes "wait agent-running" 'key \032' "wait out:is suspended" 'key fg\n' "finish" "wait poweroff"
  [ "$(events fg)" = "agent-running agent-done poweroff" ] && grep -q 'is suspended — fg resumes it' $T/fg/out.txt \
    && ok "ctrl+z leaves a prompt that says so; fg resumes the agent; the VM powers off when it ends" \
    || { bad "ctrl+z/fg: events '$(events fg)'"; tail -20 $T/fg/out.txt >&2; }

  # --- ctrl+z, then exit ---------------------------------------------------------------------
  run abandon yes "wait agent-running" 'key \032' "wait out:is suspended" 'key exit\n' "wait out:stopped jobs" 'key exit\n' "wait poweroff"
  [ "$(events abandon)" = "agent-running poweroff" ] \
    && ok "a suspended agent abandoned with exit (twice) powers the VM off" \
    || { bad "ctrl+z/exit: events '$(events abandon)'"; tail -20 $T/abandon/out.txt >&2; }

  # --- the agent ends ----------------------------------------------------------------------------
  run plain yes "wait agent-running" "finish" "wait poweroff"
  [ "$(events plain)" = "agent-running agent-done poweroff" ] && ! grep -q 'is suspended' $T/plain/out.txt \
    && ok "an agent that ends powers the VM off, with no suspend hint" \
    || { bad "plain: events '$(events plain)'"; tail -20 $T/plain/out.txt >&2; }

  # --- shells that are not the console's ------------------------------------------------------
  # No events is only worth something from a shell that ran the init and got
  # to a prompt: the profile says it sourced the init, and a command typed at
  # the prompt answers (up-42, which the echo of the typed line cannot show).
  ready () { grep -q '^init-sourced$' $T/$1/out.txt && grep -q '^up-42$' $T/$1/out.txt; }
  run other no 'key echo up-$((6*7))\n' "wait out:^up-42" 'key exit\n' "wait out:logout"
  ready other && [ "$(events other)" = "" ] && ok "a login shell on another terminal starts no agent and powers nothing off" \
    || { bad "another terminal: events '$(events other)'"; tail -20 $T/other/out.txt >&2; }
  EXTRA=MICROVM_AGENT=claude run nested yes 'key echo up-$((6*7))\n' "wait out:^up-42" 'key exit\n' "wait out:logout"
  ready nested && [ "$(events nested)" = "" ] && ok "nor does one on the console below the agent (MICROVM_AGENT set)" \
    || { bad "nested: events '$(events nested)'"; tail -20 $T/nested/out.txt >&2; }

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
