# Regression test for the memory-seed race in programs.bash.interactiveShellInit
# (modules/base.nix, modules/cri.nix, modules/agents/claude.nix).
#
# The seed blocks append to ~/.claude/CLAUDE.md, which lives on a host share and
# outlives the VM, so each block is guarded by a `grep -q '<!-- MARKER -->'`.
# That guard is idempotent across boots but was not atomic within one: the guest
# opens two logins at once (console and tty1), and on the first boot after a new
# block is introduced both shells passed the check before either appended,
# seeding it twice. Nothing failed loudly — the agent just carried a duplicated
# copy of its own instructions in every context window.
#
# Both halves matter. The structural checks pin the lock in place at eval time
# and catch a new seed block added outside it; the booted VM actually races
# concurrent shells against the real rendered init, which is the only way to
# observe the interleaving the guard alone does not prevent.
#
# The marker list is read back out of the rendered shell init rather than
# repeated here, so a new seed block extends this test for free.
{ pkgs, lib, config }:

let
  init = config.programs.bash.interactiveShellInit;

  closeTok = "exec 9>&-";
  parts = lib.splitString closeTok init;

  # Everything from the start through the final lock release: the seeding, with
  # the agent launch and `sudo poweroff` that follow it left behind.
  seedRegion = lib.concatStringsSep closeTok (lib.init parts) + closeTok;

  # Text that no lock is held over: before the first `flock`, after each release.
  outside = let
    chunks = lib.splitString "flock 9" init;
    after = map (c: lib.concatStringsSep closeTok (lib.drop 1 (lib.splitString closeTok c)))
      (lib.drop 1 chunks);
  in lib.concatStrings ([ (lib.head chunks) ] ++ after);

  countOf = tok: (lib.length (lib.splitString tok init)) - 1;

  # A marker on a line of its own is one that gets appended; the indented,
  # quoted ones in the grep guards and the CRI-SUDO cleanup sed are not.
  markers = lib.unique (lib.filter (m: m != null) (map (l:
    let m = builtins.match "<!-- ([A-Z0-9-]+) -->" l;
    in if m == null then null else lib.head m) (lib.splitString "\n" seedRegion)));

  structural = [
    {
      name = "the seeding is wrapped in a lock that is acquired and released";
      ok = countOf "flock 9" > 0 && countOf "flock 9" == countOf closeTok;
    }
    {
      # Regions are siblings, not nested: re-opening fd 9 inside a held lock
      # would silently drop the outer one.
      name = "every lock region uses the same lock file";
      ok = countOf "\${XDG_RUNTIME_DIR:-/tmp}/claude-vm-seed.lock" == countOf "flock 9";
    }
    {
      name = "no CLAUDE.md write happens outside a lock region";
      ok = !(lib.hasInfix "~/.claude/CLAUDE.md" outside);
    }
    {
      name = "the launch/poweroff tail is not part of the seeding region";
      ok = !(lib.hasInfix "sudo poweroff" seedRegion);
    }
    {
      name = "there is something to seed";
      ok = markers != [ ];
    }
  ];

  seedScript = pkgs.writeText "seed-region.sh" seedRegion;
in
pkgs.testers.runNixOSTest {
  name = "seed-idempotence";

  nodes.machine = { ... }: {
    environment.systemPackages = [ pkgs.git pkgs.util-linux ];
  };

  testScript = ''
    # A name -> 1/0 mapping, not a list of records: the driver type-checks the
    # script as Python, where JSON `true` is undefined and a dict of mixed
    # value types makes every lookup `str | int`.
    structural = ${builtins.toJSON (lib.listToAttrs
      (map (c: lib.nameValuePair c.name (if c.ok then 1 else 0)) structural))}
    markers = ${builtins.toJSON markers}

    machine.wait_for_unit("multi-user.target")

    with subtest("the rendered shell init keeps its lock structure"):
        for name, ok in structural.items():
            assert ok, name
            print(f"ok: {name}")

    def seed(home, shells):
        machine.succeed(
            f"for i in $(seq 1 {shells}); do "
            f"(HOME={home} bash ${seedScript} >/dev/null 2>&1) & done; wait"
        )

    def counts(home):
        return {
            m: int(machine.succeed(
                f"grep -c '^<!-- {m} -->' {home}/.claude/CLAUDE.md || true").strip())
            for m in markers
        }

    # Concurrent logins on a CLAUDE.md that does not yet carry the blocks: the
    # first boot after a new one is added, which is when the race bit.
    with subtest("concurrent shells seed each block exactly once"):
        for r in range(1, 4):
            home = f"/tmp/seed{r}"
            machine.succeed(f"mkdir -p {home}/.claude && : > {home}/.claude/CLAUDE.md")
            seed(home, 8)
            for m, n in counts(home).items():
                assert n == 1, f"round {r}: {m} appears {n} times, expected 1"

    # The guard's original job: a file that already carries the blocks is left
    # alone, however many times a shell starts.
    with subtest("re-running over an already-seeded file changes nothing"):
        home = "/tmp/seed1"
        before = machine.succeed(f"sha256sum < {home}/.claude/CLAUDE.md")
        seed(home, 8)
        seed(home, 1)
        assert machine.succeed(f"sha256sum < {home}/.claude/CLAUDE.md") == before
        for m, n in counts(home).items():
            assert n == 1, f"after re-run: {m} appears {n} times, expected 1"
  '';
}
