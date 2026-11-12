# One login per boot (modules/console.nix): the agent user is logged in on the
# console and nowhere else.
#
# Every autologin runs the shell init, which starts the agent and powers the VM
# off when it exits, so a second login is a second agent — unseen, on a
# terminal nobody watches, and able to take the VM down under the first. That
# is how it went wrong: getty@tty1 was disabled, but NixOS's getty module also
# makes getty.target want autovt@tty1, the same template under another name.
#
# This boots the module and counts the agent's sessions rather than checking
# unit names, so it catches whatever starts the next one: a new `wants`, a
# systemd generator, a changed alias. The driver keeps hvc0 and ttyS0 for
# itself and disables their gettys, so the console here is a UART of its own,
# pinned to ttyS1 (the driver adds its -serial after these options, and would
# otherwise take index 1). It reaches its getty the way hvc0 does on a real
# guest: through systemd-getty-generator and console=.
{ pkgs }:

pkgs.testers.runNixOSTest {
  name = "single-console";

  nodes.machine = { ... }: {
    imports = [ ../modules/console.nix ];
    claude-vm.console = "ttyS1";
    virtualisation.qemu.options =
      [ "-chardev" "null,id=agent-console" "-device" "isa-serial,chardev=agent-console,index=1" ];
    users.users.agent = { isNormalUser = true; };
  };

  testScript = ''
    import json

    def agent_sessions():
        out = machine.succeed("loginctl list-sessions --json=short")
        # Logins only: the agent's systemd --user manager is a session of its
        # own (class "manager"), with no terminal.
        return [s for s in json.loads(out)
                if s["user"] == "agent" and s["class"].startswith("user")]

    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds(
        "loginctl list-sessions --json=short | grep -q '\"user\":\"agent\"'", timeout=120)
    # Logins race each other to start, and logind registers each as it
    # arrives; give any second one time to show up before counting.
    machine.wait_for_unit("getty.target")
    machine.sleep(10)

    sessions = agent_sessions()
    print(f"agent sessions: {sessions}")
    assert len(sessions) == 1, f"expected one agent login, got {len(sessions)}: {sessions}"
    assert sessions[0]["tty"] == "ttyS1", f"the agent is logged in on {sessions[0]['tty']}, not the console"
  '';
}
