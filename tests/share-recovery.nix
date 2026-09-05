# Eval-level pins for the virtiofs share recovery path (modules/base.nix,
# scripts/vm-share-relieve.sh). The tool needs root, so it re-execs itself
# through a sudo rule that names its install path as a literal string — nothing
# checks that the two agree, and if they drift the failure surfaces only when
# someone is already stuck with an unusable share and no way out but a restart.
{ pkgs, lib, config }:

let
  toolName = "vm-share-relieve";
  toolPath = "/run/current-system/sw/bin/${toolName}";

  sudoCommands = lib.concatMap (rule: map (c: c.command) rule.commands)
    config.security.sudo.extraRules;

  installed = lib.any (p: (p.meta.mainProgram or "") == toolName)
    config.environment.systemPackages;

  checks = [
    {
      name = "the recovery tool is installed in the guest";
      ok = installed;
    }
    {
      name = "sudo permits it, at the exact path it re-execs";
      ok = lib.elem toolPath sudoCommands;
    }
    {
      name = "it is permitted without a password (the agent has no password)";
      ok = lib.any (rule:
        lib.any (c: c.command == toolPath && lib.elem "NOPASSWD" c.options)
          rule.commands) config.security.sudo.extraRules;
    }
    {
      # The script hardcodes the path for the re-exec, because sudo rules match
      # on the literal command. Keep that string honest.
      name = "the script re-execs through that same path";
      ok = lib.hasInfix "exec sudo -n ${toolPath}"
        (builtins.readFile ../scripts/vm-share-relieve.sh);
    }
  ];
in
pkgs.runCommand "share-recovery" { } (''
  fail=0
'' + lib.concatMapStrings ({ name, ok }: ''
  if ${if ok then "true" else "false"}; then
    echo "ok: ${name}"
  else
    echo "FAIL: ${name}" >&2
    fail=1
  fi
'') checks + ''
  [ "$fail" -eq 0 ] || exit 1
  touch $out
'')
