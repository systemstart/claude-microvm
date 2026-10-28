{ lib, config, ... }:
let
  console = config.claude-vm.console;
in
{
  options.claude-vm.console = lib.mkOption {
    type = lib.types.str;
    default = "hvc0";
    internal = true;
    description = ''
      The one terminal the agent user is logged in on, and so the one that
      starts the agent: every autologin runs the shell init, which launches
      the agent and powers the VM off when it exits. A second login would run
      a second agent, unseen, and its exit would take the VM down under the
      first.

      Only tests/single-console.nix sets it, because the test driver keeps
      hvc0 for itself.
    '';
  };

  config = {
    boot.kernelParams = [ "console=${console}" ];

    # Autologin applies to every getty, so whatever starts a getty on another
    # terminal starts another agent there. The console's own comes from
    # systemd-getty-generator (console=); the two VT ones below are what NixOS
    # starts without being asked. getty@tty1 is the obvious one, but its
    # getty module also makes getty.target want autovt@tty1 — an alias of the
    # same template, which disabling getty@tty1 does not reach. Anything else
    # that turns up later is caught by tests/single-console.nix, which boots
    # this module and counts the logins rather than checking these names.
    services.getty.autologinUser = "agent";
    systemd.services."getty@tty1".enable = false;
    systemd.services."autovt@tty1".enable = false;
  };
}
