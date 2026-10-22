# The launch scope (flake.nix, "Launch scope"), against a real systemd --user.
#
# tests/instance-share.nix checks, with systemd-run stubbed, that the launcher
# asks for a scope and binds its daemons to it. Whether that does anything is
# up to systemd, so here it runs for real: a NixOS VM with a lingering user,
# the built launcher started from a login session as it would be from a
# terminal, real systemd-run, real virtiofsd. Only QEMU is replaced, by a
# stand-in that stays up — as a VM would — until told to exit.
#
#   - the launcher and its "VM" run in the launch scope, which with the three
#     virtiofsd units makes up the launch's own slice, nested in
#     claude_microvm.slice; the units are bound to the scope, described, and
#     tagged in the journal with the launch's ID;
#   - stopping that slice stops the whole launch, and its cleanup runs;
#   - killing the launcher with SIGKILL, which no trap sees, leaves the daemons
#     running while the VM does, and systemd stops them when it exits;
#   - `systemctl --user stop <scope>` stops the VM, and the launcher's cleanup
#     still runs: its daemons and instance dir go;
#   - a VM that exits normally leaves nothing.
{ pkgs, lib, runner }:

let
  # The built launcher with QEMU, and only QEMU, swapped for $FAKE_QEMU — and
  # its scope probe made to fail when FAKE_NO_SCOPE=false, since systemd here
  # grants a scope even outside a session, and the unscoped path needs testing.
  launcher = pkgs.runCommand "microvm-run-fake-qemu" { } ''
    sed -E \
      -e 's|^( *)bash <\(|\1"$FAKE_QEMU" <(|' \
      -e 's|--scope --quiet --collect -- true 2>&1\)|--scope --quiet --collect -- "''${FAKE_NO_SCOPE:-true}" 2>\&1)|' \
      ${runner}/bin/microvm-run > $out
    grep -q '"$FAKE_QEMU" <(' $out || { echo "the QEMU invocation moved; update the pattern" >&2; exit 1; }
    grep -qF -- '-- "''${FAKE_NO_SCOPE:-true}" 2>&1)' $out || { echo "the scope probe moved; update the pattern" >&2; exit 1; }
    chmod +x $out
  '';
  # Answers QMP on one connection; the power button, or quit, "powers off".
  qmpResponder = pkgs.writeShellScript "fake-qmp" ''
    echo '{"QMP": {"version": {}, "capabilities": []}}'
    while IFS= read -r line; do
      echo '{"return": {}}'
      case "$line" in *system_powerdown*|*'"quit"'*) touch "$FAKE_QEMU_EXIT" ;; esac
    done
  '';
  # Stays up, like a running VM, until $FAKE_QEMU_EXIT appears, serving QMP
  # where the launcher told QEMU to (its -qmp, in the script it was handed).
  # SIGTERM takes the QMP listener with it, as QEMU's own socket goes with it.
  fakeQemu = pkgs.writeShellScript "fake-qemu" ''
    echo $$ > "$FAKE_QEMU_PID"
    qmp=$(grep -o -- '-qmp unix:[^,]*' "$1" | head -1); qmp="''${qmp#-qmp unix:}"
    ${pkgs.socat}/bin/socat UNIX-LISTEN:"$qmp",fork EXEC:${qmpResponder} &
    listener=$!
    trap 'kill $listener 2>/dev/null; exit 143' TERM
    while [ ! -e "$FAKE_QEMU_EXIT" ]; do sleep 0.2; done
    kill $listener 2>/dev/null || true
  '';
in
pkgs.testers.runNixOSTest {
  name = "launch-scope";

  nodes.machine = { ... }: {
    users.users.alice = { isNormalUser = true; uid = 1000; linger = true; };
    # A logind session for `su`, so the launcher starts where a terminal
    # login's shell would: in a session scope, outside the user manager.
    security.pam.services.su.startSession = true;
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    import json, shlex
    from datetime import timedelta

    ROOT = "/run/user/1000/claude-microvm"

    def alice(cmd):
        env = "export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; "
        return "su -l alice -c " + shlex.quote(env + cmd)

    def user(args):
        return alice("systemctl --user " + args)

    def prop(unit, name):
        return machine.succeed(user(f"show -p {name} --value {unit}")).strip()

    def launch(n, unscoped=False):
        # A project name long enough that the launcher keeps only its first
        # 12 characters, so the instance dir's socket paths under the real
        # /run/user/1000 are as long as they get by default.
        project = f"{n}-a-long-project-name"
        machine.succeed(alice(
            f"mkdir -p ~/{project} && cd ~/{project} && "
            + ("FAKE_NO_SCOPE=false " if unscoped else "") +
            f"FAKE_QEMU=${fakeQemu} FAKE_QEMU_PID=/tmp/qemu{n}.pid FAKE_QEMU_EXIT=/tmp/exit{n} NO_PAUSE=1 "
            f"setsid -f ${launcher} </dev/null >/tmp/launch{n}.log 2>&1"))
        machine.wait_until_succeeds(f"test -s /tmp/qemu{n}.pid", timeout=timedelta(seconds=120))
        # Found as a tool would: the instance.json under vms/ whose project is
        # this one; its dir is then vms/<id>, from the ID alone.
        for path in machine.succeed(f"ls {ROOT}/vms/*/instance.json").split():
            inst = json.loads(machine.succeed(f"cat {path}"))
            if inst["work"] == f"/home/alice/{project}":
                break
        else:
            raise AssertionError(f"no instance.json under {ROOT}/vms for {project}")
        d = f"{ROOT}/vms/{inst['id']}"
        assert path == f"{d}/instance.json", path
        return inst, d, machine.succeed(f"cat /tmp/qemu{n}.pid").strip()

    def units_named(pattern):
        out = machine.succeed(user(f"list-units --no-legend --plain --all '{pattern}'"))
        return {line.split()[0] for line in out.splitlines() if line.strip()}

    def daemons(inst):
        return [inst["units"][k] for k in ("work", "agentHome", "guest")]

    def wait_stopped(unit):
        machine.wait_until_fails(user(f"is-active --quiet {unit}"), timeout=timedelta(seconds=60))

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")

    with subtest("the launch runs in its scope, in its own slice, and its daemons are bound to it"):
        inst, d, qemu = launch(1)
        scope, slice, lid = inst["units"]["scope"], inst["slice"], inst["id"]
        assert scope == f"claude_microvm-{lid}.scope", f"scope is {scope!r}"
        assert slice == f"claude_microvm-{lid}.slice", f"slice is {slice!r}"
        machine.succeed(user(f"is-active --quiet {scope}"))
        assert prop(scope, "Slice") == slice
        # Nested by its name: the launch's slice is in claude_microvm.slice.
        assert prop(slice, "Slice") == "claude_microvm.slice", f"{slice} is in {prop(slice, 'Slice')}"
        assert prop(scope, "Description") == f"claude microvm {lid}: the VM, for {inst['work']}", prop(scope, "Description")
        cgroup = prop(scope, "ControlGroup")
        for pid in (inst["pid"], qemu):
            got = machine.succeed(f"cut -d: -f3 /proc/{pid}/cgroup").strip()
            assert got == cgroup, f"pid {pid} is in {got}, not the scope's {cgroup}"
        for u in daemons(inst):
            machine.succeed(user(f"is-active --quiet {u}"))
            assert scope in prop(u, "BindsTo").split(), f"{u} is not bound to {scope}"
            assert scope in prop(u, "After").split(), f"{u} is not ordered after {scope}"
            assert prop(u, "Slice") == slice, f"{u} is in {prop(u, 'Slice')}, not {slice}"
            desc = prop(u, "Description")
            assert desc.startswith(f"claude microvm {lid}: ") and desc.endswith(f", for {inst['work']}"), f"{u}: {desc!r}"
        # The slice holds the launch and nothing else: the scope and its daemons.
        members = units_named(f"claude_microvm-{lid}*")
        assert members == {scope, slice} | {f"{u}.service" for u in daemons(inst)}, members
        machine.succeed(f"journalctl MICROVM_ID={inst['id']} -o cat | grep -q .")

    with subtest("SIGKILL of the launcher: the daemons outlive it while the VM runs, then stop"):
        machine.succeed(f"kill -KILL {inst['pid']}")
        machine.wait_until_fails(f"kill -0 {inst['pid']}", timeout=timedelta(seconds=10))
        machine.sleep(2)
        machine.succeed(user(f"is-active --quiet {scope}"))
        for u in daemons(inst):
            machine.succeed(user(f"is-active --quiet {u}"))
        machine.succeed(f"kill {qemu}")
        for u in daemons(inst):
            wait_stopped(u)
        wait_stopped(scope)
        # No trap ran, so the instance dir is still there: removing it is the
        # stale sweep's job, which has not been written yet.
        machine.succeed(f"rm -rf {d}")

    with subtest("stopping the scope stops the VM, and the launcher still cleans up"):
        inst, d, qemu = launch(2)
        machine.succeed(user(f"stop {inst['units']['scope']}"))
        machine.wait_until_fails(f"test -e {d}", timeout=timedelta(seconds=60))
        for u in daemons(inst):
            wait_stopped(u)

    with subtest("stopping the launch's slice stops all of it, and the launcher still cleans up"):
        inst, d, qemu = launch(4)
        machine.succeed(user(f"stop {inst['slice']}"))
        machine.wait_until_fails(f"test -e {d}", timeout=timedelta(seconds=60))
        for u in daemons(inst) + [inst["units"]["scope"]]:
            wait_stopped(u)

    STOP = "${runner}/bin/microvm-stop"

    with subtest("microvm-stop powers off a scoped launch, and the launcher cleans up"):
        inst, d, qemu = launch(5)
        assert inst["units"]["scope"], inst
        out = machine.succeed(alice(f"{STOP} {inst['id']}"))
        assert f"{inst['id']} stopped" in out, out
        machine.succeed(f"test ! -e {d}")
        for u in daemons(inst) + [inst["units"]["scope"]]:
            wait_stopped(u)

    with subtest("microvm-stop powers off an unscoped launch, and the launcher cleans up"):
        inst, d, qemu = launch(6, unscoped=True)
        assert inst["units"]["scope"] is None, f"the scope probe was meant to fail: {inst['units']}"
        machine.succeed("grep -q 'cannot run this launch in a systemd --user scope' /tmp/launch6.log")
        out = machine.succeed(alice(f"{STOP} {inst['id']}"))
        assert f"{inst['id']} stopped" in out, out
        machine.succeed(f"test ! -e {d}")
        for u in daemons(inst):
            wait_stopped(u)

    with subtest("a VM that exits normally leaves nothing"):
        inst, d, qemu = launch(3)
        machine.succeed("touch /tmp/exit3")
        machine.wait_until_fails(f"test -e {d}", timeout=timedelta(seconds=60))
        for u in daemons(inst) + [inst["units"]["scope"]]:
            wait_stopped(u)
        # The slice itself stays, empty, until logout; nothing is left in it.
        left = units_named(f"claude_microvm-{inst['id']}*")
        assert left <= {inst["slice"]}, left
        # The shared root and vms/ stay, empty, until logout.
        machine.succeed(f"test -d {ROOT}/vms && test -z \"$(ls -A {ROOT}/vms)\"")
        machine.fail("grep -i error /tmp/launch3.log")
  '';
}
