{
  description = "Claude Code microVM";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, microvm }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosConfigurations.claude-vm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          microvm.nixosModules.microvm
          ({ pkgs, ... }: {
            nixpkgs.config.allowUnfree = true;

            networking.hostName = "claude-vm";

            microvm = {
              hypervisor = "qemu";
              mem = 4096;
              vcpu = 4;

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
                commands = [{
                  command = "/run/current-system/sw/bin/poweroff";
                  options = [ "NOPASSWD" ];
                }];
              }];
            };

            environment.systemPackages = with pkgs; [
              claude-code
              git
              openssh
              cacert
            ];

            environment.variables = {
              SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
            };

            programs.bash.interactiveShellInit = ''
              git config --global --add safe.directory /work 2>/dev/null || true
              cd /work 2>/dev/null || true
              claude; sudo poweroff
            '';

            systemd.tmpfiles.rules = [
              "d /work 0755 claude claude -"
            ];


            nix.settings.experimental-features = [ "nix-command" "flakes" ];
            nix.gc = {
              automatic = true;
              dates = "daily";
              options = "--delete-older-than 7d";
            };

            documentation.enable = false;

            system.stateVersion = "25.05";
          })
        ];
      };

      packages.${system} = rec {
        default = vm;

        vm = let
        runner = self.nixosConfigurations.claude-vm.config.microvm.runner.qemu;
        virtiofsd = pkgs.virtiofsd;
      in pkgs.writeShellScriptBin "microvm-run" ''
        set -euo pipefail
        WORK="$(realpath "''${WORK_DIR:-$(pwd)}")"
        RUNTIME="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        ID=$(echo -n "$WORK" | sha256sum | cut -c1-8)
        SOCK="$RUNTIME/claude-vm-virtiofs-$ID.sock"
        UNIT="claude-vm-virtiofsd-$ID"
        STATE="$RUNTIME/claude-vm-virtiofsd-$ID.workdir"

        # (Re)start virtiofsd if not running or WORK_DIR changed
        NEED_START=1
        if ${pkgs.systemd}/bin/systemctl --user is-active "$UNIT" &>/dev/null; then
          if [ -f "$STATE" ] && [ "$(cat "$STATE")" = "$WORK" ] && [ -S "$SOCK" ]; then
            NEED_START=0
          else
            ${pkgs.systemd}/bin/systemctl --user stop "$UNIT" 2>/dev/null || true
          fi
        fi

        if [ "$NEED_START" = "1" ]; then
          rm -f "$SOCK"

          # virtiofsd runs unprivileged in a user namespace (--sandbox=namespace).
          # --uid-map / --gid-map: map host user to namespace root (single-entry, no /etc/subuid needed)
          # --translate-uid / --translate-gid: map guest uid/gid 1000 to namespace uid/gid 0 (= host user)
          ${pkgs.systemd}/bin/systemd-run --user --unit="$UNIT" --collect \
            -- ${virtiofsd}/bin/virtiofsd \
              --socket-path="$SOCK" \
              --shared-dir="$WORK" \
              --sandbox=namespace \
              --uid-map ":0:$(id -u):1:" \
              --gid-map ":0:$(id -g):1:" \
              --translate-uid "map:1000:0:1" \
              --translate-gid "map:1000:0:1" \
              --socket-group="$(id -gn)" \
              --xattr

          echo "$WORK" > "$STATE"

          # Wait for socket
          for i in $(seq 1 50); do
            [ -S "$SOCK" ] && break
            sleep 0.1
          done
          [ -S "$SOCK" ] || { echo "error: virtiofsd socket did not appear"; exit 1; }
        fi

        # Run QEMU with corrected paths
        bash <(${pkgs.gnused}/bin/sed \
          -e "s|/tmp/claude-vm-work|$WORK|g" \
          -e "s|claude-vm-virtiofs-work.sock|$SOCK|g" \
          ${runner}/bin/microvm-run)
      '';
      };
    };
}
