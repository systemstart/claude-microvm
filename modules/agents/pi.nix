{ pkgs, ... }:
{
  claude-vm.agent = {
    name = "pi";
    launchCommand = "pi";
    extraPackages = [ pkgs.pi-coding-agent ];
    shellInit = "";
  };
}
