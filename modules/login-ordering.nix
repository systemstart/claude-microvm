# The units the agent's login has to wait for, whose own ordering names a getty
# that never runs.
#
# microvm-policy orders these before getty@hvc0.service, but the console's
# getty is serial-getty@hvc0, which systemd-getty-generator makes from
# console=hvc0 (modules/console.nix); getty@hvc0 stays inactive, so that
# ordering holds the login back for nothing. Each has to be done before the
# agent starts: the shell init's refusal for a failed seal only works once the
# seal's self-test has run, the guard's binds have to be up before the agent
# can write under them, and the ephemeral check finds no overlay until it is
# mounted.
#
# Every login waits for systemd-user-sessions.service, whatever its terminal,
# so these are ordered before that instead. `before` is a list and merges with
# microvm-policy's. Fix it in microvm-policy and this module goes away;
# tests/login-ordering.nix holds the rule for every unit either way.
{ ... }:

{
  systemd.services = {
    egress-seal.before = [ "systemd-user-sessions.service" ];
    work-ephemeral.before = [ "systemd-user-sessions.service" ];
    workspace-guard.before = [ "systemd-user-sessions.service" ];
  };
}
