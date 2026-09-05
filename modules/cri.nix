{ pkgs, lib, config, ... }:
let
  cfg = config.claude-vm.cri;
in
{
  options.claude-vm.cri = {
    enable = lib.mkEnableOption "container runtime support";

    storageSize = lib.mkOption {
      type = lib.types.int;
      default = 30720;
      description = ''
        Maximum size of the CRI storage volume in MiB. The image is sparse, so
        this is a cap rather than an allocation: it consumes only what is
        actually written. Overridable at runtime via the CRI_STORAGE_SIZE env
        var, which applies to a freshly created image only — see README
        "Container runtime support".
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    microvm.mem = lib.mkDefault 8192;

    programs.bash.interactiveShellInit = ''
      # Seed CRI usage info into Claude Code's user-level memory (only if ~/.claude exists)
      if [ -d ~/.claude ]; then
        # Clean up old sudo reminder if present
        if grep -q '<!-- CRI-SUDO -->' ~/.claude/CLAUDE.md 2>/dev/null; then
          sed -i '/<!-- CRI-SUDO -->/,/permission errors\./d' ~/.claude/CLAUDE.md
        fi
        if ! grep -q '<!-- CRI-USAGE -->' ~/.claude/CLAUDE.md 2>/dev/null; then
          cat >> ~/.claude/CLAUDE.md << 'CRIEOF'

<!-- CRI-USAGE -->
# Container Runtime Usage

Container runtime CLIs work without `sudo`:
- `docker ...`
- `nerdctl ...`
- `crictl ...`
- `kubectl ...`
- `podman ...`

No `sudo` needed — the CLIs connect to daemon sockets that are
configured with appropriate group permissions for the agent user.
CRIEOF
        fi
      fi
      export CONTAINER_HOST=unix:///run/podman/podman.sock
    '';

    # Container storage must live on a real block-backed filesystem, NOT a
    # virtiofs share. The host virtiofsd runs rootless with a single-ID uid/gid
    # map, so it cannot lchown extracted layer files to UID 0 — overlay2/KinD
    # image unpack fails with "lchown /bin: operation not permitted" and
    # `docker info` reports `Backing Filesystem: fuse`. A dedicated ext4 volume
    # gives the guest a genuine root-capable fs (Backing Filesystem: extfs).
    # The sparse image is created on the host and persists in agent home; the
    # runner script (flake.nix) rewrites the `cri-storage.img` path accordingly.
    microvm.volumes = [
      {
        image = "cri-storage.img";
        label = "cri-storage";
        mountPoint = "/var/lib/containers";
        # Sparse: a cap, not an allocation. The runner rewrites the generated
        # `truncate -s <size>M` when CRI_STORAGE_SIZE is set (see flake.nix).
        size = cfg.storageSize;
        fsType = "ext4";
      }
    ];

    # `CRI_STORAGE_SIZE=0` on the host launches without this drive at all, for
    # people who want the VM's isolation and no artifacts on their disk. Boot
    # must not care: `nofail` keeps the mount out of local-fs.target's
    # requirements and out of its ordering, so a device that never appears is
    # skipped rather than waited on, and /var/lib/containers stays an ordinary
    # directory on the rootfs. The short device timeout only bounds how long the
    # pending job lingers; without it the default is 90s.
    #
    # Safe here precisely because this mount is not `neededForBoot` — the same
    # trick is not available to the writable store overlay, which the initrd
    # requires.
    fileSystems."/var/lib/containers".options = [
      "nofail"
      "x-systemd.device-timeout=5s"
    ];

    boot.kernelModules = [ "overlay" "br_netfilter" "veth" "ip_tables" "nf_nat" "xt_conntrack" ];
    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.ipv4.ip_forward" = 1;
    };

    users.groups.docker = {};
    users.users.agent.extraGroups = [ "docker" ];

    environment.systemPackages = with pkgs; [
      containerd
      runc
      crun
      cri-o
      conmon
      cni-plugins
      cri-tools
      nerdctl
      kubectl
      iptables
      docker
      docker-compose
      podman
    ];

    environment.etc = {
      "cni/net.d/10-bridge.conflist".text = builtins.toJSON {
        cniVersion = "1.0.0";
        name = "bridge";
        plugins = [
          {
            type = "bridge";
            bridge = "cni0";
            isGateway = true;
            ipMasq = true;
            ipam = {
              type = "host-local";
              ranges = [ [ { subnet = "10.88.0.0/16"; gateway = "10.88.0.1"; } ] ];
              routes = [ { dst = "0.0.0.0/0"; } ];
            };
          }
          { type = "portmap"; capabilities = { portMappings = true; }; }
          { type = "firewall"; }
          { type = "tuning"; }
        ];
      };

      "containerd/config.toml".text = ''
        version = 3
        root = "/var/lib/containers/containerd"
        state = "/run/containerd"

        [grpc]
          address = "/run/containerd/containerd.sock"
          gid = 1000

        [plugins."io.containerd.cri.v1.images"]
          sandbox_image = "registry.k8s.io/pause:3.10"

        [plugins."io.containerd.cri.v1.runtime"]
          snapshotter = "overlayfs"
          [plugins."io.containerd.cri.v1.runtime".cni]
            bin_dir = "${pkgs.cni-plugins}/bin"
            conf_dir = "/etc/cni/net.d"
          [plugins."io.containerd.cri.v1.runtime".containerd]
            default_runtime_name = "runc"
            [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc]
              runtime_type = "io.containerd.runc.v2"
              [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]
                SystemdCgroup = true
                BinaryName = "${pkgs.runc}/bin/runc"
      '';

      "containerd/config-crun.toml".text = ''
        version = 3
        root = "/var/lib/containers/containerd-crun"
        state = "/run/containerd-crun"

        [grpc]
          address = "/run/containerd-crun/containerd.sock"
          gid = 1000

        [plugins."io.containerd.cri.v1.images"]
          sandbox_image = "registry.k8s.io/pause:3.10"

        [plugins."io.containerd.cri.v1.runtime"]
          snapshotter = "overlayfs"
          [plugins."io.containerd.cri.v1.runtime".cni]
            bin_dir = "${pkgs.cni-plugins}/bin"
            conf_dir = "/etc/cni/net.d"
          [plugins."io.containerd.cri.v1.runtime".containerd]
            default_runtime_name = "crun"
            [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.crun]
              runtime_type = "io.containerd.runc.v2"
              [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.crun.options]
                SystemdCgroup = true
                BinaryName = "${pkgs.crun}/bin/crun"
      '';

      "crio/crio.conf".text = ''
        [crio]
          root = "/var/lib/containers/crio/storage"
          runroot = "/run/containers/storage"
          storage_driver = "overlay"

        [crio.api]
          listen = "/run/crio/crio.sock"

        [crio.image]
          pause_image = "registry.k8s.io/pause:3.10"

        [crio.network]
          network_dir = "/etc/cni/net.d"
          plugin_dirs = ["${pkgs.cni-plugins}/bin"]

        [crio.runtime]
          conmon = "${pkgs.conmon}/bin/conmon"
          cgroup_manager = "systemd"
          default_runtime = "runc"

          [crio.runtime.runtimes.runc]
            runtime_path = "${pkgs.runc}/bin/runc"
            runtime_type = "oci"

          [crio.runtime.runtimes.crun]
            runtime_path = "${pkgs.crun}/bin/crun"
            runtime_type = "oci"
      '';

      "docker/daemon.json".text = builtins.toJSON {
        data-root = "/var/lib/containers/docker";
        storage-driver = "overlay2";
        group = "docker";
        iptables = true;
      };

      "containers/policy.json".text = builtins.toJSON {
        default = [ { type = "insecureAcceptAnything"; } ];
      };

      "containers/registries.conf".text = ''
        unqualified-search-registries = ["docker.io"]
      '';

      "containers/storage.conf".text = ''
        [storage]
          driver = "overlay"
          graphroot = "/var/lib/containers/podman"
      '';

      "nerdctl/nerdctl.toml".text = ''
        address = "unix:///run/containerd/containerd.sock"
      '';
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/containers 0755 root root -"
    ];

    systemd.services.containerd = {
      description = "containerd container runtime";
      after = [ "network.target" "var-lib-containers.mount" ];
      wants = [ "network.target" ];
      wantedBy = [ ];
      # containerd-shim-runc-v2 resolves the OCI runtime by PATH lookup unless the
      # runtime options carry an absolute BinaryName. The CRI plugin sets one (see
      # config.toml above), but the moby namespace does not: when dockerd finds this
      # containerd already running it attaches instead of starting its own, and its
      # containers then die with `exec: "runc": executable file not found in $PATH`.
      # Same for `ctr` and rootful nerdctl in the default namespace. See
      # docs/CRI-GOTCHAS.md.
      path = [ pkgs.runc pkgs.crun ];
      serviceConfig = {
        ExecStart = "${pkgs.containerd}/bin/containerd --config /etc/containerd/config.toml";
        Restart = "always";
        RestartSec = 5;
        Delegate = true;
        KillMode = "process";
        OOMScoreAdjust = -999;
        LimitNOFILE = 1048576;
        LimitNPROC = "infinity";
        LimitCORE = "infinity";
        RuntimeDirectory = "containerd";
      };
    };

    systemd.services.containerd-crun = {
      description = "containerd container runtime (crun)";
      after = [ "network.target" "var-lib-containers.mount" ];
      wants = [ "network.target" ];
      wantedBy = [ ];
      # Same shim PATH gap as above — its CRI runtime pins crun absolutely, but any
      # other namespace on this socket would fall back to a PATH lookup.
      path = [ pkgs.runc pkgs.crun ];
      serviceConfig = {
        ExecStart = "${pkgs.containerd}/bin/containerd --config /etc/containerd/config-crun.toml";
        Restart = "always";
        RestartSec = 5;
        Delegate = true;
        KillMode = "process";
        OOMScoreAdjust = -999;
        LimitNOFILE = 1048576;
        LimitNPROC = "infinity";
        LimitCORE = "infinity";
        RuntimeDirectory = "containerd-crun";
      };
    };

    systemd.services.cri-activate = {
      description = "Activate CRI runtimes based on ENABLE_CRI";
      after = [ "network.target" "home-agent.mount" "var-lib-containers.mount" ];
      before = [ "getty@tty1.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ENV_FILE="/home/agent/.microvm-env"
        [ -f "$ENV_FILE" ] && source "$ENV_FILE"

        ENABLE_CRI="''${ENABLE_CRI:-}"
        [ -z "$ENABLE_CRI" ] && exit 0

        IFS=',' read -ra RUNTIMES <<< "$ENABLE_CRI"

        FIRST_ENDPOINT=""
        for rt in "''${RUNTIMES[@]}"; do
          rt="$(echo "$rt" | tr -d ' ')"
          case "$rt" in
            containerd)
              systemctl start containerd
              [ -z "$FIRST_ENDPOINT" ] && FIRST_ENDPOINT="unix:///run/containerd/containerd.sock"
              echo "cri-activate: started containerd (unix:///run/containerd/containerd.sock)"
              ;;
            crun)
              systemctl start containerd-crun
              [ -z "$FIRST_ENDPOINT" ] && FIRST_ENDPOINT="unix:///run/containerd-crun/containerd.sock"
              echo "cri-activate: started containerd-crun (unix:///run/containerd-crun/containerd.sock)"
              ;;
            crio)
              systemctl start crio
              # Wait for socket and fix permissions for claude
              for i in $(seq 1 50); do
                [ -S /run/crio/crio.sock ] && break
                sleep 0.2
              done
              if [ -S /run/crio/crio.sock ]; then
                chgrp agent /run/crio/crio.sock
                chmod 0660 /run/crio/crio.sock
              fi
              [ -z "$FIRST_ENDPOINT" ] && FIRST_ENDPOINT="unix:///run/crio/crio.sock"
              echo "cri-activate: started crio (unix:///run/crio/crio.sock)"
              ;;
            docker)
              systemctl start docker
              echo "cri-activate: started docker (unix:///var/run/docker.sock)"
              ;;
            podman)
              systemctl start podman.socket
              echo "cri-activate: started podman (unix:///run/podman/podman.sock)"
              ;;
            *)
              echo "cri-activate: unknown runtime: $rt" >&2
              ;;
          esac
        done

        # Write crictl config with first available endpoint
        if [ -n "$FIRST_ENDPOINT" ]; then
          printf 'runtime-endpoint: %s\nimage-endpoint: %s\ntimeout: 10\n' \
            "$FIRST_ENDPOINT" "$FIRST_ENDPOINT" > /etc/crictl.yaml
        fi
      '';
    };

    systemd.services.crio = {
      description = "CRI-O container runtime";
      after = [ "network.target" "var-lib-containers.mount" ];
      wants = [ "network.target" ];
      wantedBy = [ ];
      serviceConfig = {
        ExecStart = "${pkgs.cri-o}/bin/crio --config /etc/crio/crio.conf";
        Restart = "always";
        RestartSec = 5;
        Delegate = true;
        KillMode = "process";
        OOMScoreAdjust = -999;
        LimitNOFILE = 1048576;
        LimitNPROC = "infinity";
        LimitCORE = "infinity";
        RuntimeDirectory = [ "crio" "containers/storage" ];
      };
    };

    systemd.services.docker = {
      description = "Docker daemon";
      after = [ "network.target" "var-lib-containers.mount" ];
      wants = [ "network.target" ];
      wantedBy = [ ];
      serviceConfig = {
        ExecStart = "${pkgs.docker}/bin/dockerd --config-file /etc/docker/daemon.json";
        Restart = "always";
        RestartSec = 5;
        Delegate = true;
        KillMode = "process";
        OOMScoreAdjust = -999;
        LimitNOFILE = 1048576;
        LimitNPROC = "infinity";
        LimitCORE = "infinity";
      };
    };

    systemd.sockets.podman = {
      description = "Podman API Socket";
      wantedBy = [ ];
      listenStreams = [ "/run/podman/podman.sock" ];
      socketConfig = {
        SocketMode = "0660";
        SocketUser = "root";
        SocketGroup = "agent";
      };
    };

    systemd.services.podman = {
      description = "Podman API Service";
      requires = [ "podman.socket" ];
      after = [ "podman.socket" "network.target" "var-lib-containers.mount" ];
      wantedBy = [ ];
      serviceConfig = {
        ExecStart = "${pkgs.podman}/bin/podman system service --time=0";
        Restart = "always";
        RestartSec = 5;
        Delegate = true;
        KillMode = "process";
        OOMScoreAdjust = -999;
        LimitNOFILE = 1048576;
        LimitNPROC = "infinity";
        LimitCORE = "infinity";
      };
    };
  };
}
