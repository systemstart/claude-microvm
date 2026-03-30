{ pkgs, ... }:
{
  claude-vm.agent = {
    name = "gemini";
    launchCommand = "gemini";
    extraPackages = [ pkgs.gemini-cli ];
    shellInit = "";
  };
}
