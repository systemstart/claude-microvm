# Phase 8 regression test: on-demand autoload of net/sched modules stays blocked.
#
# This runs the real modules/hardening.nix in a booted VM, with the test driver
# as root. That matters: the agent user inside a claude-vm guest is denied sudo
# for modprobe, so the blocking cannot be exercised by hand from inside a live
# VM — a `sudo modprobe` there fails on the sudo policy and tells you nothing
# about whether the install rules work.
#
# The module lists are read back out of the module under test rather than
# repeated here, so adding an entry to hardening.nix extends this test for free
# and a hardcoded list cannot rot beside a maintained one.
{ pkgs }:

pkgs.testers.runNixOSTest {
  name = "module-hardening";

  nodes.machine = { ... }: {
    imports = [ ../modules/hardening.nix ];
    environment.systemPackages = [ pkgs.iproute2 pkgs.kmod ];
  };

  testScript = { nodes, ... }: let
    inherit (nodes.machine.claude-vm.hardening)
      blockedKernelModules requiredKernelModules knownUnblockableModules;
  in ''
    blocked = ${builtins.toJSON blockedKernelModules}
    required = ${builtins.toJSON requiredKernelModules}
    unblockable = ${builtins.toJSON knownUnblockableModules}

    machine.wait_for_unit("multi-user.target")

    # The premise of this test: unlike a live guest, we are root here.
    machine.succeed("test $(id -u) -eq 0")

    with subtest("every blocked module has an install rule"):
        for m in blocked:
            machine.succeed(f"grep -q '^install {m} ' /etc/modprobe.d/nixos.conf")

    with subtest("install target is an absolute store path, not /bin/false"):
        # NixOS /bin holds exactly one entry (sh), so a bare /bin/false would
        # exit 127 "command not found" — refused by accident rather than by
        # design, and noisy in the log. Pin that it stays a store path.
        machine.succeed(
            "grep -qE '^install .* /nix/store/.*/bin/false$' /etc/modprobe.d/nixos.conf"
        )
        machine.fail("grep -qE '^install .* /bin/false$' /etc/modprobe.d/nixos.conf")

    with subtest("blocked modules refuse to load, for the right reason"):
        for m in blocked:
            if m in unblockable:
                continue
            status, out = machine.execute(f"modprobe {m} 2>&1")
            assert status != 0, f"{m}: modprobe unexpectedly succeeded"
            # Distinguishes "our install rule refused it" from "the module is
            # simply absent from this kernel", which would pass vacuously.
            assert "Error running install command" in out, \
                f"{m}: refused for the wrong reason: {out!r}"
            machine.fail(f"grep -q '^{m} ' /proc/modules")

    with subtest("no module escapes its install rule except the known ones"):
        # kmod ignores an `install` command for any module carrying a softdep,
        # so a future kernel adding one to a listed module would silently make
        # it loadable again. Catch that here rather than in an incident.
        escaped = [
            m for m in blocked
            if "install" not in machine.execute(f"modprobe --show-depends {m} 2>&1")[1]
        ]
        assert sorted(escaped) == sorted(unblockable), (
            f"escape set changed: expected {sorted(unblockable)}, got {sorted(escaped)}. "
            "If a module gained a softdep, add it to knownUnblockableModules and say "
            "why; if one lost its softdep, drop it from that list so it is enforced."
        )

    with subtest("keep-list still loads"):
        for m in required:
            machine.succeed(f"modprobe {m}")
            machine.succeed(f"grep -q '^{m} ' /proc/modules")

    with subtest("real autoload path via tc is blocked"):
        # The kernel reaches these through request_module() on first use, which
        # runs /sbin/modprobe and so honours the install rules. This is the path
        # an attacker actually takes; the modprobe calls above only prove the
        # rules parse.
        machine.succeed("ip link add dummy0 type dummy")
        machine.succeed("tc qdisc add dev dummy0 root handle 1: prio")
        machine.fail(
            "tc filter add dev dummy0 parent 1: protocol ip prio 1 "
            "u32 match ip dst 1.2.3.4 flowid 1:1"
        )
        machine.fail("tc qdisc add dev dummy0 handle 2: parent 1:1 qfq")
        machine.succeed(
            "tc qdisc add dev dummy0 handle 3: parent 1:2 "
            "tbf rate 1mbit burst 32kbit latency 400ms"
        )
  '';
}
