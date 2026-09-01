{ pkgs, lib, config, ... }:
let
  cfg = config.claude-vm.agent;
in
{
  imports = [ ./hardening.nix ];

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
    mem = lib.mkOption {
      type = lib.types.int;
      default = 8192;
      description = "VM memory in MB. Overridable at runtime via VM_MEM env var.";
    };
    vcpu = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "VM vCPU count. Overridable at runtime via VM_VCPU env var.";
    };
  };

  config = {
    nixpkgs.config.allowUnfree = true;

    networking.hostName = "${cfg.name}-vm";

    microvm = {
      hypervisor = "qemu";
      mem = cfg.mem;
      vcpu = cfg.vcpu;

      writableStoreOverlay = "/nix/.rw-store";

      shares = [
        {
          tag = "ro-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          proto = "9p";
          readOnly = true;
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

    # /etc/systemd/system-shutdown is a symlink into the store, and the store's
    # lower layer is the 9p share, which is torn down before systemd-shutdown
    # runs its shutdown hooks. The chase then fails against a still-mounted
    # overlay with a dead lower — EIO, not ENOENT — and systemd logs
    # "Failed to chase and open directory ... ignoring" on every poweroff.
    # NixOS creates the entry solely to hold `systemd.shutdown` hooks, so with
    # none defined it is an empty directory. Drop it: a directory that is
    # simply absent is skipped silently (conf-files.c only logs when
    # `r != -ENOENT`). Guarded so that defining a hook restores the entry
    # rather than silently dropping it on the floor.
    environment.etc."systemd/system-shutdown".enable =
      lib.mkIf (config.systemd.shutdown == { }) false;

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
      NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
      TERM = lib.mkDefault "xterm-256color";
      # Force nix CLI through the daemon. Without this, if the daemon socket
      # is missing (e.g. nix-daemon.socket failed to start), nix falls back to
      # single-user mode and the agent user — who can't write /nix/var/nix —
      # fails with "creating directory /nix/var/nix/temproots: Permission
      # denied". With NIX_REMOTE=daemon the failure is loud and actionable
      # ("cannot connect to daemon") instead.
      NIX_REMOTE = "daemon";
    };

    programs.bash.interactiveShellInit = ''
      git config --global --add safe.directory /work 2>/dev/null || true

      ${cfg.shellInit}

      cd /work 2>/dev/null || true
      # `set -a` so these are exported, not just set as shell variables: the
      # agent runs as a child process below and would not otherwise inherit
      # API keys or anything forwarded via EXTRA_ENV.
      if [ -f ~/.microvm-env ]; then
        set -a
        source ~/.microvm-env
        set +a
      fi
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
      eval "${cfg.launchCommand} ''${AGENTS_ARGS:-}"
      sudo poweroff
    '';

    systemd.tmpfiles.rules = [
      "d /work 0755 agent agent -"
    ];

    systemd.services.microvm-ca-certs = {
      description = "Inject custom CA certificates into system trust store";
      after = [ "home-agent.mount" ];
      before = [ "getty@hvc0.service" "nix-daemon.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        CA_DIR="/home/agent/.microvm-ca-certs"
        [ ! -d "$CA_DIR" ] && exit 0

        CERTS=$(find "$CA_DIR" -maxdepth 1 -type f 2>/dev/null)
        [ -z "$CERTS" ] && exit 0

        SYSTEM_BUNDLE="/etc/ssl/certs/ca-bundle.crt"
        REAL_BUNDLE="$(readlink -f "$SYSTEM_BUNDLE")"

        COMBINED="$(mktemp)"
        cat "$REAL_BUNDLE" > "$COMBINED"
        echo "" >> "$COMBINED"
        echo "# --- Custom CA certificates (injected by microvm-ca-certs) ---" >> "$COMBINED"
        for cert in $CERTS; do
          echo "# Source: $(basename "$cert")" >> "$COMBINED"
          cat "$cert" >> "$COMBINED"
          echo "" >> "$COMBINED"
        done

        rm -f "$SYSTEM_BUNDLE"
        mv "$COMBINED" "$SYSTEM_BUNDLE"
        chmod 0444 "$SYSTEM_BUNDLE"
        echo "microvm-ca-certs: injected $(echo "$CERTS" | wc -l) custom certificate file(s)"
      '';
    };

    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      extra-substituters = [ "https://devenv.cachix.org" ];
      extra-trusted-public-keys = [ "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" ];
    };

    # GC is unsafe in this overlay setup: once microvm-import-nix-db marks
    # host-lowerdir paths as valid, GC would try to delete the ones without
    # GC roots, which on overlayfs creates whiteouts in the tmpfs upperdir
    # and hides host paths from /nix/store.
    nix.gc.automatic = false;

    # Replace the boot-fresh nix DB with a snapshot of the host's DB so that
    # every path visible via the /nix/.ro-store overlay lowerdir is known to
    # be valid. Pulled in via WantedBy=nix-daemon.service so it runs before
    # the daemon (Before) on first activation. Avoid `before nix-daemon.socket`
    # or `before multi-user.target`: nix-daemon.socket is in sockets.target
    # which activates before multi-user.target, so ordering against it from a
    # multi-user-wanted unit creates a cycle that systemd resolves by skipping
    # the socket — leaving nix-daemon unreachable.
    systemd.services.microvm-import-nix-db = {
      description = "Import host nix store DB snapshot";
      after = [ "home-agent.mount" ];
      before = [ "nix-daemon.service" ];
      wantedBy = [ "nix-daemon.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        SRC=/home/agent/.microvm-nix-db.sqlite
        DST=/nix/var/nix/db/db.sqlite
        if [ -f "$SRC" ]; then
          install -m 0644 "$SRC" "$DST"
          echo "microvm-import-nix-db: imported host DB ($(stat -c%s "$DST") bytes)"
        else
          echo "microvm-import-nix-db: no host DB snapshot at $SRC, skipping"
        fi
      '';
    };

    documentation.enable = false;

    system.stateVersion = "25.05";
  };
}
