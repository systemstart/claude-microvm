{ pkgs, lib, config, ... }:
let
  cfg = config.claude-vm.cri;
in
{
  options.claude-vm.cri.enable = lib.mkEnableOption "container runtime support";

  config = lib.mkIf cfg.enable {
    microvm.mem = lib.mkDefault 8192;

    programs.bash.interactiveShellInit = ''
      # Clean up old sudo reminder if present
      if grep -q '<!-- CRI-SUDO -->' ~/.claude/CLAUDE.md 2>/dev/null; then
        sed -i '/<!-- CRI-SUDO -->/,/permission errors\./d' ~/.claude/CLAUDE.md
      fi
      # Seed CRI usage info into Claude's user-level memory
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
configured with appropriate group permissions for the claude user.
CRIEOF
      fi
      export CONTAINER_HOST=unix:///run/podman/podman.sock
    '';

    microvm.shares = [
      {
        tag = "cri-storage";
        source = "/tmp/claude-vm-cri-storage";
        mountPoint = "/var/lib/containers";
        proto = "virtiofs";
      }
    ];

    boot.kernelModules = [ "overlay" "br_netfilter" "veth" "ip_tables" "nf_nat" "xt_conntrack" ];
    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.ipv4.ip_forward" = 1;
    };

    users.groups.docker = {};
    users.users.claude.extraGroups = [ "docker" ];

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
      after = [ "network.target" "home-claude.mount" "var-lib-containers.mount" ];
      before = [ "getty@tty1.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ENV_FILE="/home/claude/.microvm-env"
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
                chgrp claude /run/crio/crio.sock
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
        SocketGroup = "claude";
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
