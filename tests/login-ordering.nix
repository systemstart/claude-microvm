# What the agent's login waits for (modules/base.nix, modules/cri.nix,
# modules/login-ordering.nix): every unit that means to finish before the agent
# starts is ordered before systemd-user-sessions.service.
#
# The units used to name a getty instead, and named the wrong one: the console's
# getty is serial-getty@hvc0, from systemd-getty-generator, so `before =
# getty@hvc0` (the CA bundle, the egress seal, the workspace guard and overlay)
# and `before = getty@tty1` (the container runtimes) ordered nothing, and the
# login raced them. On a booted guest, cri-activate finished after the login
# started. systemd-user-sessions is what every login waits for, whatever its
# terminal.
#
# The rule is read off the evaluated config, not a list kept here: any service
# whose `before` names a getty must also be before systemd-user-sessions, so a
# new unit written the old way fails here too. The named units are checked as
# well, so that dropping the getty from one cannot take it out of the rule.
#
# What evaluation cannot show is that the order holds at boot without a cycle;
# that was checked by hand on nested KVM (systemd-user-sessions' After= has all
# five, and the journal has no ordering cycle).
{ pkgs, lib, config }:

let
  sessions = "systemd-user-sessions.service";
  services = config.systemd.services;
  beforeOf = s: services.${s}.before or [ ];

  isGetty = u: builtins.match "(serial-getty|getty|autovt|container-getty|console-getty)[@.].*" u != null;

  namesGetty = lib.filter (s: lib.any isGetty (beforeOf s)) (lib.attrNames services);

  wanted = [ "microvm-ca-certs" "cri-activate" "egress-seal" "work-ephemeral" "workspace-guard" ];

  checks =
    map (s: {
      name = "${s} is before ${sessions}";
      ok = services ? ${s} && lib.elem sessions (beforeOf s);
    }) wanted
    ++ map (s: {
      name = "${s} names a getty in before=, and is also before ${sessions}";
      ok = lib.elem sessions (beforeOf s);
    }) namesGetty;
in
pkgs.runCommand "login-ordering" { } ''
  fail=0
  ${lib.concatMapStrings (c: if c.ok then ''echo ${lib.escapeShellArg "ok: ${c.name}"}
  '' else ''echo ${lib.escapeShellArg "FAIL: ${c.name}"} >&2; fail=1
  '') checks}
  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
