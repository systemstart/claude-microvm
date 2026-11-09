{ pkgs, ... }:
{
  claude-vm.agent = {
    name = "gemini";
    launchCommand = "gemini";
    extraPackages = [ pkgs.gemini-cli ];
    shellInit = "";
  };

  # 2026-11-09: nixpkgs marks gemini-cli for removal (meta.problems.removal):
  # Google replaced Gemini CLI with Antigravity CLI for the free tier and for
  # Google AI Pro/Ultra subscribers. Until then the package builds and works,
  # with an API key too, and the notice is a warning on every evaluation of
  # this flavor. Silenced here, for this package and this problem only.
  # When nixpkgs drops the package, this flavor stops evaluating: then
  # package Gemini CLI here (if API-key use still works) or replace the
  # flavor, e.g. with Antigravity CLI once nixpkgs has it.
  nixpkgs.config.problems.handlers.gemini-cli.removal = "ignore";
}
