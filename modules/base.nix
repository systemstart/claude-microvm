{ pkgs, lib, config, ... }:
let
  cfg = config.claude-vm.agent;
in
{
  options.claude-vm.agent = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Agent name, used for hostname and display messages";
    };
    launchCommand = lib.mkOption {
      type = lib.types.str;
      description = "Command to exec on login to start the agent";
    };
    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = "Agent-specific packages to install";
    };
    shellInit = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Agent-specific shell init (runs before launch)";
    };
  };

  config = {
    nixpkgs.config.allowUnfree = true;

    networking.hostName = "${cfg.name}-vm";

    microvm = {
      hypervisor = "qemu";
      mem = 4096;
      vcpu = 4;

      writableStoreOverlay = "/nix/.rw-store";

      shares = [
        {
          tag = "ro-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          proto = "9p";
        }
        {
          tag = "work";
          source = "/tmp/${cfg.name}-vm-work";
          mountPoint = "/work";
          proto = "virtiofs";
        }
        {
          tag = "agent-home";
          source = "/tmp/${cfg.name}-vm-home";
          mountPoint = "/home/agent";
          proto = "virtiofs";
        }
      ];

      # Use virtio-console (hvc0) instead of serial (ttyS0) for the
      # interactive console.  virtio batches data in shared-memory buffers,
      # avoiding the character-by-character UART emulation that causes TUI
      # flickering in agents like Gemini CLI.
      qemu.serialConsole = false;
      qemu.extraArgs = [
        "-device" "virtio-serial-pci"
        "-device" "virtconsole,chardev=stdio"
        "-netdev" "user,id=usernet"
        "-device" "virtio-net-device,netdev=usernet"
      ];
    };

    users.groups.agent.gid = 1000;
    users.users.agent = {
      isNormalUser = true;
      uid = 1000;
      group = "agent";
      home = "/home/agent";
      shell = pkgs.bash;
    };

    boot.kernelParams = [ "console=hvc0" ];

    services.getty.autologinUser = "agent";
    systemd.services."getty@tty1".enable = false;

    users.motd = "";

    programs.bash.logout = ''
      sudo poweroff
    '';

    security.sudo = {
      enable = true;
      extraRules = [{
        users = [ "agent" ];
        commands = [
          { command = "/run/current-system/sw/bin/poweroff"; options = [ "NOPASSWD" ]; }
          { command = "/run/current-system/sw/bin/systemctl"; options = [ "NOPASSWD" ]; }
          { command = "/run/current-system/sw/bin/journalctl"; options = [ "NOPASSWD" ]; }
        ];
      }];
    };

    environment.systemPackages = with pkgs; [
      devenv
      git
      openssh
      cacert
    ] ++ cfg.extraPackages;

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    environment.variables = {
      SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
      TERM = lib.mkDefault "xterm-256color";
    };

    programs.bash.interactiveShellInit = ''
      git config --global --add safe.directory /work 2>/dev/null || true

      ${cfg.shellInit}

      cd /work 2>/dev/null || true
      [ -f ~/.microvm-env ] && source ~/.microvm-env
      if [ "''${DIRENV_ALLOW:-0}" = "1" ]; then
        if [ -f ~/.microvm-devshell ] && [ -s ~/.microvm-devshell ]; then
          echo "loading dev environment..."
          _ORIG_PATH="$PATH"
          source ~/.microvm-devshell 2>/dev/null || true
          export PATH="$PATH:$_ORIG_PATH"
          unset _ORIG_PATH
        else
          echo "warning: dev shell cache not found — ensure DIRENV_ALLOW=1 is set on host"
          [ -f ~/.microvm-devshell.err ] && cat ~/.microvm-devshell.err
        fi
      fi
      echo "starting ${cfg.name} ..."
      ${cfg.launchCommand}; sudo poweroff
    '';

    systemd.tmpfiles.rules = [
      "d /work 0755 agent agent -"
    ];

    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      extra-substituters = [ "https://devenv.cachix.org" ];
      extra-trusted-public-keys = [ "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" ];
    };
    nix.gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 7d";
    };

    documentation.enable = false;

    system.stateVersion = "25.05";
  };
}
