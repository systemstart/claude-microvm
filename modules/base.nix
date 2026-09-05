{ pkgs, lib, config, ... }:
let
  cfg = config.claude-vm.agent;
  storeCfg = config.claude-vm.store;

  # Reclaiming space in the writable store is a footgun here — `nix-collect-garbage`
  # walks every host path visible through the overlay's lower layer and writes a
  # whiteout for it into the upper one — so ship the safe recipe as a command
  # rather than leave it to be reinvented under disk pressure. See the script
  # header and docs/NIX-STORE-GOTCHAS.md.
  vmStorePrune = pkgs.writeShellApplication {
    name = "vm-store-prune";
    runtimeInputs = with pkgs; [ coreutils findutils gnugrep gnused nix ];
    text = builtins.readFile ../scripts/vm-store-prune.sh;
  };

  vmStoreAutoPrune = pkgs.writeShellApplication {
    name = "vm-store-autoprune";
    runtimeInputs = with pkgs; [ coreutils vmStorePrune ];
    text = builtins.readFile ../scripts/vm-store-autoprune.sh;
  };

  # Recovery for an ENFILE-wedged virtiofs share. The guest cannot fix this
  # without root — and without a way to fix it, the only exit is a VM restart.
  # See docs/VIRTIOFS-GOTCHAS.md; the sudo rule below names its install path.
  vmShareRelieve = pkgs.writeShellApplication {
    name = "vm-share-relieve";
    runtimeInputs = with pkgs; [ coreutils gawk ];
    text = builtins.readFile ../scripts/vm-share-relieve.sh;
  };
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

  options.claude-vm.store = {
    diskBacked = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Back the writable half of /nix/store with a sparse ext4 volume on the
        host instead of the VM's RAM-backed root filesystem.

        Everything nix writes inside the guest lands in that overlay: build
        outputs, substituted paths, and — the one that bites — a full copy of
        the working tree every time a flake input is a dirty git worktree,
        which is the normal state while working. Those `…-source` snapshots run
        to hundreds of MiB each and a fresh one is minted per distinct dirty
        state, so on tmpfs a day of `nix develop` churn fills RAM and the VM
        starts failing writes with ENOSPC. On a volume the same churn costs
        host disk, which is the resource there is plenty of.

        The volume is recreated empty on every launch, so the guest still boots
        with an empty writable store, and `vm-store-prune` reclaims space
        without a restart.
      '';
    };

    size = lib.mkOption {
      type = lib.types.int;
      default = 10240;
      description = ''
        Cap on the writable store volume in MiB. The image is sparse, so this is
        a ceiling rather than an allocation: what it costs the host up front is
        the filesystem metadata, ~69 MiB at any cap up to 10 GiB (ext4 doubles
        that somewhere before 20 GiB). It is a containment boundary as much as a
        budget — the guest should not be able to eat an unbounded amount of the
        host's disk. Raise it with the VM_STORE_SIZE env var for workloads that
        genuinely need more. No effect unless `diskBacked` is set.
      '';
    };

    autoPrune = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run `vm-store-prune` from a timer when free space in the writable
          store drops below `freeMiB`.

          This is the safe counterpart to nix's own `min-free`, which must stay
          disabled here: `min-free` calls the full garbage collector, which on
          this overlay deletes the host's store paths behind whiteouts. Same
          trigger, wrong collector.

          A tick that finds space costs one statfs. Runs cannot overlap, and
          consecutive passes that free nothing back off to two hours, so a store
          pinned by a live dev shell does not turn into a re-walk every
          interval.
        '';
      };

      freeMiB = lib.mkOption {
        type = lib.types.int;
        default = 2048;
        description = ''
          Low watermark in MiB. Deliberately well clear of zero: pruning needs
          to write to the nix database, so it has to run before the store is
          actually full, not after.
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "5min";
        description = ''
          How long after a run finishes to check again (systemd time span).
          Measured from completion, not from a wall clock, so ticks can neither
          overlap nor accumulate a backlog.
        '';
      };
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

      # The writable half of the store, on a disk rather than in RAM — see
      # `claude-vm.store.diskBacked`. Same shape as the CRI volume: a sparse
      # ext4 image the runner creates on the host before boot, identified by
      # label rather than drive letter so the two volumes cannot swap places.
      # Declaring `mountPoint == writableStoreOverlay` is what makes microvm.nix
      # mark this filesystem `neededForBoot`, so it is mounted in the initrd
      # before the overlay that uses it as upperdir.
      volumes = lib.mkIf storeCfg.diskBacked [
        {
          image = "nix-store-overlay.img";
          label = "nix-rw-store";
          mountPoint = config.microvm.writableStoreOverlay;
          size = storeCfg.size;
          fsType = "ext4";
        }
      ];

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
          # Drops the guest's dentry/inode caches, which is what releases the
          # host virtiofsd's file descriptors. Narrow by design: the command
          # takes no arguments that change what it does, and the worst it can
          # do is make the guest's own lookups cold for a moment.
          { command = "/run/current-system/sw/bin/vm-share-relieve"; options = [ "NOPASSWD" ]; }
        ];
      }];
    };

    environment.systemPackages = with pkgs; [
      devenv
      git
      openssh
      cacert
      vmStorePrune
      vmShareRelieve
    ] ++ cfg.extraPackages;

    # Timer-driven cleanup for the writable store. Deliberately not wanted by
    # any target: the timer below is the only thing that starts it.
    systemd.services.vm-store-autoprune = lib.mkIf storeCfg.autoPrune.enable {
      description = "Prune VM-local Nix store paths when the writable store runs low";
      environment.VM_STORE_PRUNE_FREE_MIB = toString storeCfg.autoPrune.freeMiB;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe vmStoreAutoPrune;
        # Housekeeping must never compete with the agent's own work; deletion is
        # I/O-bound, so the I/O class is the one that matters.
        Nice = 19;
        IOSchedulingClass = "idle";
        # Backstop only. A prune killed part-way is safe — deletion happens in
        # the daemon, path by path — and the next tick picks up where it left off.
        TimeoutStartSec = "30min";
      };
    };

    systemd.timers.vm-store-autoprune = lib.mkIf storeCfg.autoPrune.enable {
      description = "Periodic check of writable Nix store free space";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = storeCfg.autoPrune.interval;
        # From when the service last *finished*, not from a schedule: a run that
        # takes longer than the interval delays the next tick instead of having
        # one queued behind it, and a missed window is never made up in a burst.
        OnUnitInactiveSec = storeCfg.autoPrune.interval;
        # The check is cheap but not urgent; let systemd coalesce the wakeups.
        AccuracySec = "1min";
      };
    };

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

      # ENFILE on a share is an obscure failure with a non-obvious recovery, and
      # the agent is the one who will hit it. Seed the recognition and the fix.
      if [ -d ~/.claude ] && ! grep -q '<!-- MICROVM-SHARE-ENFILE -->' ~/.claude/CLAUDE.md 2>/dev/null; then
        cat >> ~/.claude/CLAUDE.md << 'SHAREEOF'

<!-- MICROVM-SHARE-ENFILE -->
# "Too many open files" on /work or /home/agent

If ENFILE appears on the **shares** — not on `/` or `/nix/store` — the host's
virtiofs daemon has run out of file descriptors. It holds one per inode this VM
has looked up and gets it back only when this VM drops the dentry, so your own
fd counters look perfectly healthy while every operation on the share fails.
It does not clear on its own, and retrying makes it worse: each retry is more
lookups.

1. Stop whatever is walking the share, including your own retry loop.
2. Run `vm-share-relieve` — it forces the cache eviction that hands the
   descriptors back, and handles the sudo itself.

Avoid unbounded traversals of `/work` in the first place: depth-limit `find`,
and prune `node_modules`, `vendor`, module caches and rendered output. Prefer
explicit path lists over discovery in anything that iterates repositories.
SHAREEOF
      fi

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
    ] ++ lib.optional storeCfg.diskBacked
      "d ${config.microvm.writableStoreOverlay}/tmp 0755 root root -";

    # Nix builds unpack into TMPDIR, which defaults to /tmp — the RAM-backed
    # rootfs. One large unpack (a container image, a vendored module cache) can
    # take the VM out with ENOSPC while the store volume beside it sits nearly
    # empty. Point the daemon at the volume instead: the build output has to end
    # up there anyway, and same-filesystem means the final move into the store is
    # a rename rather than a copy.
    systemd.services.nix-daemon.environment = lib.mkIf storeCfg.diskBacked {
      TMPDIR = "${config.microvm.writableStoreOverlay}/tmp";
    };

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
