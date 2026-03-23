{ pkgs, ... }:
{
  nixpkgs.config.allowUnfree = true;

  networking.hostName = "claude-vm";

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
        source = "/tmp/claude-vm-work";
        mountPoint = "/work";
        proto = "virtiofs";
      }
      {
        tag = "claude-home";
        source = "/tmp/claude-vm-home";
        mountPoint = "/home/claude";
        proto = "virtiofs";
      }
    ];

    qemu.extraArgs = [
      "-netdev" "user,id=usernet"
      "-device" "virtio-net-device,netdev=usernet"
    ];
  };

  users.groups.claude.gid = 1000;
  users.users.claude = {
    isNormalUser = true;
    uid = 1000;
    group = "claude";
    home = "/home/claude";
    shell = pkgs.bash;
  };

  services.getty.autologinUser = "claude";

  users.motd = "";

  programs.bash.logout = ''
    sudo poweroff
  '';

  security.sudo = {
    enable = true;
    extraRules = [{
      users = [ "claude" ];
      commands = [
        { command = "/run/current-system/sw/bin/poweroff"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/systemctl"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/journalctl"; options = [ "NOPASSWD" ]; }
      ];
    }];
  };

  environment.systemPackages = with pkgs; [
    claude-code
    devenv
    git
    openssh
    cacert
  ];

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  environment.variables = {
    SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
    DISABLE_AUTOUPDATER = "1";
  };

  programs.bash.interactiveShellInit = ''
    git config --global --add safe.directory /work 2>/dev/null || true

    # Seed microVM disk-space awareness into Claude's user-level memory
    mkdir -p ~/.claude
    if ! grep -q '<!-- MICROVM-DISK-SPACE -->' ~/.claude/CLAUDE.md 2>/dev/null; then
      cat >> ~/.claude/CLAUDE.md << 'VMEOF'

<!-- MICROVM-DISK-SPACE -->
# MicroVM Disk Space

You are running inside a microVM with a RAM-backed writable filesystem.
Disk space is severely limited. **Check disk space proactively** before
operations that consume storage (installing packages, building projects,
downloading files, writing large outputs).

## How to check

```bash
df -h / /nix
```

## Thresholds

- **Low space (<10% free)**: Warn the user immediately. Suggest cleanup:
  `sudo nix-collect-garbage -d` and `rm -rf /tmp/*`
- **No space left (0% free or write failures like "No space left on device")**:
  Stop what you are doing and tell the user. Prioritise freeing space before
  continuing any other work. Run `sudo nix-collect-garbage -d`, clear `/tmp`,
  and verify space was reclaimed with `df -h`.

Keep this in mind throughout the entire session.
VMEOF
    fi

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
    echo "starting claude ..."
    claude; sudo poweroff
  '';

  systemd.tmpfiles.rules = [
    "d /work 0755 claude claude -"
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
}
