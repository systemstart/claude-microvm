{ pkgs, ... }:
{
  claude-vm.agent = {
    name = "codex";
    launchCommand = "codex";
    extraPackages = [ pkgs.codex ];
    shellInit = "";
  };
}
