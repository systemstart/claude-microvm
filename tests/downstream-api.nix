# Test for the interface other flakes build on: lib.mkNixosConfig and
# lib.mkRunner (flake.nix, README "Building on claude-microvm").
#
#   - without modules, mkRunner is exactly this flake's own package, so the
#     public path and packages.<flavor> cannot drift apart;
#   - a downstream module reaches the guest, and the guest settings the
#     launcher takes its defaults from (here claude-vm.agent.mem) reach the
#     launcher;
#   - the runner carries the guest it was built for, as `nixosConfig`;
#   - what would build a broken launcher is refused at evaluation: an
#     unknown flavor, or a module renaming the agent.
#
# Everything is decided at evaluation; nothing here builds a VM.
{ pkgs, lib, mkRunner, package, flavors }:

let
  system = pkgs.stdenv.hostPlatform.system;

  plain = mkRunner { inherit system; };

  downstream = mkRunner {
    inherit system;
    modules = [
      ({ pkgs, ... }: {
        environment.systemPackages = [ pkgs.hello ];
        claude-vm.agent.mem = 6144;
      })
    ];
  };
  guest = downstream.nixosConfig.config;
  launcherText = downstream.passthru.launcher.text;

  refused = r: !(builtins.tryEval (builtins.seq r.drvPath true)).success;

  # A literal substring test. lib.hasInfix is builtins.match ".*<infix>.*",
  # and some Nix builds (Determinate Nix, as CI installs it) match with a
  # regex engine that recurses per character: on the ~100 KB launcher that
  # overflows the evaluator's stack.
  contains = needle: text: builtins.replaceStrings [ needle ] [ "" ] text != text;

  checks = [
    {
      name = "mkRunner without modules is packages.claude, derivation for derivation";
      ok = plain.drvPath == package.drvPath;
    }
    {
      name = "lib.flavors lists every flavor";
      ok = lib.sort lib.lessThan flavors == [ "claude" "codex" "gemini" "pi" ];
    }
    {
      name = "a downstream module's package is in the guest";
      ok = lib.elem pkgs.hello.name (map (p: p.name or "") guest.environment.systemPackages);
    }
    {
      name = "the guest's claude-vm.agent.mem becomes the launcher's VM_MEM default";
      ok = contains ''VM_MEM="''${VM_MEM:-6144}"'' launcherText;
    }
    {
      name = "the runner carries its guest as nixosConfig";
      ok = guest.claude-vm.agent.name == "claude";
    }
    {
      name = "the downstream runner differs from the plain one";
      ok = downstream.drvPath != plain.drvPath;
    }
    {
      name = "an unknown flavor is refused";
      ok = refused (mkRunner { inherit system; flavor = "nope"; });
    }
    {
      name = "a module renaming the agent is refused";
      ok = refused (mkRunner { inherit system; modules = [ { claude-vm.agent.name = lib.mkForce "other"; } ]; });
    }
  ];
in
pkgs.runCommand "downstream-api" { } ''
  fail=0
  ${lib.concatMapStrings (c:
    if c.ok then ''echo ${lib.escapeShellArg "ok: ${c.name}"}
    '' else ''echo ${lib.escapeShellArg "FAIL: ${c.name}"} >&2; fail=1
    '') checks}
  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
