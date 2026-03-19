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
                  echo "running direnv allow ..."
                  direnv allow 2>/dev/null || true
                  echo "running direnv export ..."
                  eval "$(direnv export bash 2>/dev/null)" || true
                fi
              fi
              echo "starting claude ..."
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

      devShells.${system}.default = let
        gsemver = let
          version = "0.10.0";
          sources = {
            "x86_64-linux" = {
              url = "https://github.com/arnaud-deprez/gsemver/releases/download/v${version}/gsemver_${version}_linux_amd64.tar.gz";
              hash = "sha256-F1oyytHMSEBZTNWVyxKM6Zua2sJeQjQ3pyyPDxYDk78=";
            };
            "aarch64-linux" = {
              url = "https://github.com/arnaud-deprez/gsemver/releases/download/v${version}/gsemver_${version}_linux_arm64.tar.gz";
              hash = "sha256-PRIp6ti87aoLoKdLWnDSJLUw+uM95olpUB2ILSmtMII=";
            };
            "x86_64-darwin" = {
              url = "https://github.com/arnaud-deprez/gsemver/releases/download/v${version}/gsemver_${version}_darwin_amd64.tar.gz";
              hash = "sha256-BBKey/Gk1gDQ3uKWuBLuPqEYdjBxxVYsBytBFOOygz4=";
            };
            "aarch64-darwin" = {
              url = "https://github.com/arnaud-deprez/gsemver/releases/download/v${version}/gsemver_${version}_darwin_arm64.tar.gz";
              hash = "sha256-kH11CbkodKKWu9Nh3piGrdTAzSOV/o4Q24uzhasQUQU=";
            };
          };
          src = sources.${pkgs.stdenv.hostPlatform.system};
        in pkgs.stdenv.mkDerivation {
          pname = "gsemver";
          inherit version;
          src = pkgs.fetchurl { inherit (src) url hash; };
          sourceRoot = ".";
          dontConfigure = true;
          dontBuild = true;
          installPhase = ''
            install -Dm755 gsemver $out/bin/gsemver
          '';
        };
      in pkgs.mkShell {
        buildInputs = [ gsemver ];
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
        ID="$(cat /proc/sys/kernel/random/uuid)"

        # --- Work share (virtiofsd) ---
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

        # --- Claude home share (virtiofsd) ---
        CLAUDE_SOCK="$RUNTIME/claude-vm-virtiofs-$ID-claude-home.sock"
        CLAUDE_UNIT="claude-vm-virtiofsd-$ID-claude-home"
        CLAUDE_STATE="$RUNTIME/claude-vm-virtiofsd-$ID-claude-home.dir"

        if [ -z "''${CLAUDE_HOME:-}" ]; then
          DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
          WORK_HASH="$(echo -n "$WORK" | sha256sum | cut -c1-12)"
          CLAUDE_HOME="$DATA_HOME/claude-microvm/$WORK_HASH"
        fi
        CLAUDE_DIR="$(realpath "$CLAUDE_HOME" 2>/dev/null || echo "$CLAUDE_HOME")"
        if [ ! -d "$CLAUDE_DIR" ]; then
          mkdir -p "$CLAUDE_DIR"
        fi
        CLAUDE_TEMP=""

        cleanup() {
          ${pkgs.systemd}/bin/systemctl --user stop "$UNIT" 2>/dev/null || true
          ${pkgs.systemd}/bin/systemctl --user stop "$CLAUDE_UNIT" 2>/dev/null || true
          rm -f "$SOCK" "$CLAUDE_SOCK" "$STATE" "$CLAUDE_STATE"
          if [ -n "$CLAUDE_TEMP" ]; then
            rm -rf "$CLAUDE_TEMP"
          fi
        }
        trap cleanup EXIT

        CLAUDE_NEED_START=1
        if ${pkgs.systemd}/bin/systemctl --user is-active "$CLAUDE_UNIT" &>/dev/null; then
          if [ -f "$CLAUDE_STATE" ] && [ "$(cat "$CLAUDE_STATE")" = "$CLAUDE_DIR" ] && [ -S "$CLAUDE_SOCK" ]; then
            CLAUDE_NEED_START=0
          else
            ${pkgs.systemd}/bin/systemctl --user stop "$CLAUDE_UNIT" 2>/dev/null || true
          fi
        fi

        if [ "$CLAUDE_NEED_START" = "1" ]; then
          rm -f "$CLAUDE_SOCK"

          ${pkgs.systemd}/bin/systemd-run --user --unit="$CLAUDE_UNIT" --collect \
            -- ${virtiofsd}/bin/virtiofsd \
              --socket-path="$CLAUDE_SOCK" \
              --shared-dir="$CLAUDE_DIR" \
              --sandbox=namespace \
              --uid-map ":0:$(id -u):1:" \
              --gid-map ":0:$(id -g):1:" \
              --translate-uid "map:1000:0:1" \
              --translate-gid "map:1000:0:1" \
              --socket-group="$(id -gn)" \
              --xattr

          echo "$CLAUDE_DIR" > "$CLAUDE_STATE"

          for i in $(seq 1 50); do
            [ -S "$CLAUDE_SOCK" ] && break
            sleep 0.1
          done
          [ -S "$CLAUDE_SOCK" ] || { echo "error: claude-home virtiofsd socket did not appear"; exit 1; }
        fi

        # Write host env vars for the VM
        echo "DIRENV_ALLOW=''${DIRENV_ALLOW:-0}" > "$CLAUDE_DIR/.microvm-env"

        # Pre-cache dev shell environment on host (fast) so the VM doesn't have to evaluate nix
        if [ "''${DIRENV_ALLOW:-0}" = "1" ] && [ -f "$WORK/flake.nix" ]; then
          _DEVSHELL_CACHE="$CLAUDE_DIR/.microvm-devshell"
          _CURRENT_HASH="$(cat "$WORK/flake.nix" "$WORK/flake.lock" 2>/dev/null | sha256sum | cut -c1-16)"
          _CACHED_HASH=""
          [ -f "$_DEVSHELL_CACHE.hash" ] && _CACHED_HASH="$(cat "$_DEVSHELL_CACHE.hash")"
          if [ "$_CURRENT_HASH" != "$_CACHED_HASH" ] || [ ! -s "$_DEVSHELL_CACHE" ]; then
            echo "caching dev shell environment..."
            if nix print-dev-env --no-update-lock-file "$WORK" > "$_DEVSHELL_CACHE.tmp" 2>/dev/null; then
              mv "$_DEVSHELL_CACHE.tmp" "$_DEVSHELL_CACHE"
              echo "$_CURRENT_HASH" > "$_DEVSHELL_CACHE.hash"
            else
              rm -f "$_DEVSHELL_CACHE.tmp"
            fi
          fi
        fi

        # Run QEMU with corrected paths
        bash <(${pkgs.gnused}/bin/sed \
          -e "s|/tmp/claude-vm-work|$WORK|g" \
          -e "s|claude-vm-virtiofs-work.sock|$SOCK|g" \
          -e "s|/tmp/claude-vm-home|$CLAUDE_DIR|g" \
          -e "s|claude-vm-virtiofs-claude-home.sock|$CLAUDE_SOCK|g" \
          ${runner}/bin/microvm-run)
      '';
      };
    };
}
