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
      lib = nixpkgs.lib;
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];
      forSystems = lib.genAttrs linuxSystems;

      vmFlavors = {
        claude = { suffix = "";        agentModule = ./modules/agents/claude.nix; dataDirName = "claude-microvm"; apiKeyVars = [ "ANTHROPIC_API_KEY" ]; };
        gemini = { suffix = "-gemini"; agentModule = ./modules/agents/gemini.nix; dataDirName = "gemini-microvm"; apiKeyVars = [ "GEMINI_API_KEY" ]; };
        codex  = { suffix = "-codex";  agentModule = ./modules/agents/codex.nix;  dataDirName = "codex-microvm";  apiKeyVars = [ "OPENAI_API_KEY" ]; };
      };

      mkRunnerScript = { pkgs, runner, dataDirName, apiKeyVars, agentName }:
        let
          virtiofsd = pkgs.virtiofsd;
          hostname = "${agentName}-vm";
          apiKeyForwarding = lib.concatStringsSep "\n" (map (var:
            ''[ -n "''${${var}:-}" ] && echo "${var}=''${${var}}" >> "$AGENT_DIR/.microvm-env"''
          ) apiKeyVars);
        in pkgs.writeShellScriptBin "microvm-run" ''
        set -euo pipefail
        WORK="$(realpath "''${WORK_DIR:-$(pwd)}")"
        RUNTIME="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        ID="$(cat /proc/sys/kernel/random/uuid)"

        # Derive project basename for host-visible identifiers
        WORK_BASENAME="$(basename "$WORK" | tr -cd 'a-zA-Z0-9_-' | head -c 12)"
        [ -z "$WORK_BASENAME" ] && WORK_BASENAME="root"
        VM_ID="$WORK_BASENAME-${hostname}"

        # --- Work share (virtiofsd) ---
        SOCK="$RUNTIME/$VM_ID-virtiofs-$ID.sock"
        UNIT="$VM_ID-virtiofsd-$ID"
        STATE="$RUNTIME/$VM_ID-virtiofsd-$ID.workdir"

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

        # --- Agent home share (virtiofsd) ---
        AGENT_SOCK="$RUNTIME/$VM_ID-virtiofs-$ID-agent-home.sock"
        AGENT_UNIT="$VM_ID-virtiofsd-$ID-agent-home"
        AGENT_STATE="$RUNTIME/$VM_ID-virtiofsd-$ID-agent-home.dir"

        if [ -z "''${AGENT_HOME:-}" ]; then
          DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
          WORK_HASH="$(echo -n "$WORK" | sha256sum | cut -c1-12)"
          AGENT_HOME="$DATA_HOME/${dataDirName}/$WORK_BASENAME-$WORK_HASH"
        fi
        AGENT_DIR="$(realpath "$AGENT_HOME" 2>/dev/null || echo "$AGENT_HOME")"
        if [ ! -d "$AGENT_DIR" ]; then
          mkdir -p "$AGENT_DIR"
        fi
        AGENT_TEMP=""

        # --- CRI storage share (virtiofsd) ---
        CRI_SOCK="$RUNTIME/$VM_ID-virtiofs-$ID-cri-storage.sock"
        CRI_UNIT="$VM_ID-virtiofsd-$ID-cri-storage"
        CRI_STATE="$RUNTIME/$VM_ID-virtiofsd-$ID-cri-storage.dir"
        CRI_DIR="$AGENT_DIR/cri-storage"
        mkdir -p "$CRI_DIR"

        cleanup() {
          ${pkgs.systemd}/bin/systemctl --user stop "$UNIT" 2>/dev/null || true
          ${pkgs.systemd}/bin/systemctl --user stop "$AGENT_UNIT" 2>/dev/null || true
          ${pkgs.systemd}/bin/systemctl --user stop "$CRI_UNIT" 2>/dev/null || true
          rm -f "$SOCK" "$AGENT_SOCK" "$STATE" "$AGENT_STATE" "$CRI_SOCK" "$CRI_STATE"
          if [ -n "$AGENT_TEMP" ]; then
            rm -rf "$AGENT_TEMP"
          fi
        }
        trap cleanup EXIT

        AGENT_NEED_START=1
        if ${pkgs.systemd}/bin/systemctl --user is-active "$AGENT_UNIT" &>/dev/null; then
          if [ -f "$AGENT_STATE" ] && [ "$(cat "$AGENT_STATE")" = "$AGENT_DIR" ] && [ -S "$AGENT_SOCK" ]; then
            AGENT_NEED_START=0
          else
            ${pkgs.systemd}/bin/systemctl --user stop "$AGENT_UNIT" 2>/dev/null || true
          fi
        fi

        if [ "$AGENT_NEED_START" = "1" ]; then
          rm -f "$AGENT_SOCK"

          ${pkgs.systemd}/bin/systemd-run --user --unit="$AGENT_UNIT" --collect \
            -- ${virtiofsd}/bin/virtiofsd \
              --socket-path="$AGENT_SOCK" \
              --shared-dir="$AGENT_DIR" \
              --sandbox=namespace \
              --uid-map ":0:$(id -u):1:" \
              --gid-map ":0:$(id -g):1:" \
              --translate-uid "map:1000:0:1" \
              --translate-gid "map:1000:0:1" \
              --socket-group="$(id -gn)" \
              --xattr

          echo "$AGENT_DIR" > "$AGENT_STATE"

          for i in $(seq 1 50); do
            [ -S "$AGENT_SOCK" ] && break
            sleep 0.1
          done
          [ -S "$AGENT_SOCK" ] || { echo "error: agent-home virtiofsd socket did not appear"; exit 1; }
        fi

        # --- CRI storage virtiofsd ---
        CRI_NEED_START=1
        if ${pkgs.systemd}/bin/systemctl --user is-active "$CRI_UNIT" &>/dev/null; then
          if [ -f "$CRI_STATE" ] && [ "$(cat "$CRI_STATE")" = "$CRI_DIR" ] && [ -S "$CRI_SOCK" ]; then
            CRI_NEED_START=0
          else
            ${pkgs.systemd}/bin/systemctl --user stop "$CRI_UNIT" 2>/dev/null || true
          fi
        fi

        if [ "$CRI_NEED_START" = "1" ]; then
          rm -f "$CRI_SOCK"

          ${pkgs.systemd}/bin/systemd-run --user --unit="$CRI_UNIT" --collect \
            -- ${virtiofsd}/bin/virtiofsd \
              --socket-path="$CRI_SOCK" \
              --shared-dir="$CRI_DIR" \
              --sandbox=namespace \
              --uid-map ":0:$(id -u):1:" \
              --gid-map ":0:$(id -g):1:" \
              --translate-uid "map:1000:0:1" \
              --translate-gid "map:1000:0:1" \
              --socket-group="$(id -gn)" \
              --xattr \
              --xattrmap ":prefix:all:trusted.:user.virtiofs.::prefix:all:security.:user.virtiofs.::ok:all:::"

          echo "$CRI_DIR" > "$CRI_STATE"

          for i in $(seq 1 50); do
            [ -S "$CRI_SOCK" ] && break
            sleep 0.1
          done
          [ -S "$CRI_SOCK" ] || { echo "error: cri-storage virtiofsd socket did not appear"; exit 1; }
        fi

        # Write host env vars for the VM
        echo "DIRENV_ALLOW=''${DIRENV_ALLOW:-0}" > "$AGENT_DIR/.microvm-env"
        echo "ENABLE_CRI=''${ENABLE_CRI:-}" >> "$AGENT_DIR/.microvm-env"
        ${apiKeyForwarding}

        # Pre-cache dev shell environment on host (fast) so the VM doesn't have to evaluate nix
        _DEVSHELL_CACHE="$AGENT_DIR/.microvm-devshell"
        if [ "''${DIRENV_ALLOW:-0}" = "1" ] && [ -f "$WORK/flake.nix" ] || [ -f "$WORK/.devenv.flake.nix" ]; then
          _CURRENT_HASH="$( (cat "$WORK/flake.nix" "$WORK/flake.lock" "$WORK/.devenv.flake.nix" "$WORK/devenv.nix" "$WORK/devenv.yaml" "$WORK/devenv.lock" 2>/dev/null || true) | sha256sum | cut -c1-16)"
          _CACHED_HASH=""
          [ -f "$_DEVSHELL_CACHE.hash" ] && _CACHED_HASH="$(cat "$_DEVSHELL_CACHE.hash")"
          if [ "$_CURRENT_HASH" != "$_CACHED_HASH" ] || [ ! -s "$_DEVSHELL_CACHE" ]; then
            echo "caching dev shell environment..."
            if [ -f "$WORK/.devenv.flake.nix" ] && ! [ -f "$WORK/flake.nix" ]; then
              _CACHE_CMD="devenv print-dev-env"
            elif [ -f "$WORK/devenv.nix" ]; then
              _CACHE_CMD="nix print-dev-env --no-update-lock-file --impure $WORK"
            else
              _CACHE_CMD="nix print-dev-env --no-update-lock-file $WORK"
            fi
            if (cd "$WORK" && eval "$_CACHE_CMD") > "$_DEVSHELL_CACHE.tmp" 2>"$_DEVSHELL_CACHE.err"; then
              mv "$_DEVSHELL_CACHE.tmp" "$_DEVSHELL_CACHE"
              echo "$_CURRENT_HASH" > "$_DEVSHELL_CACHE.hash"
              rm -f "$_DEVSHELL_CACHE.err"
            else
              rm -f "$_DEVSHELL_CACHE.tmp"
            fi
          fi
        fi

        # Build sed arguments for QEMU runner
        _SED_ARGS=(
          # Process and QEMU name: inject project basename
          -e "s|microvm@${hostname}|microvm@$VM_ID|g"
          -e "s|-name ${hostname}|-name $VM_ID|g"
          # Paths and sockets
          -e "s|/tmp/${hostname}-work|$WORK|g"
          -e "s|${hostname}-virtiofs-work.sock|$SOCK|g"
          -e "s|/tmp/${hostname}-home|$AGENT_DIR|g"
          -e "s|${hostname}-virtiofs-agent-home.sock|$AGENT_SOCK|g"
          -e "s|/tmp/${hostname}-cri-storage|$CRI_DIR|g"
          -e "s|${hostname}-virtiofs-cri-storage.sock|$CRI_SOCK|g"
        )

        # Run QEMU with corrected paths
        bash <(${pkgs.gnused}/bin/sed "''${_SED_ARGS[@]}" ${runner}/bin/microvm-run)
      '';
    in
    {
      nixosConfigurations = builtins.listToAttrs (lib.flatten (map (system:
        lib.mapAttrsToList (name: flavor: {
          name = "${name}${flavor.suffix}-${system}";
          value = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              microvm.nixosModules.microvm
              ./modules/base.nix
              ./modules/cri.nix
              { claude-vm.cri.enable = true; }
              flavor.agentModule
            ];
          };
        }) vmFlavors
      ) linuxSystems));

      devShells = forSystems (system: let pkgs = nixpkgs.legacyPackages.${system}; in {
        default = let
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
      });

      packages = forSystems (system: let pkgs = nixpkgs.legacyPackages.${system}; in
        { default = self.packages.${system}.claude; } //
        builtins.mapAttrs (name: flavor: let
          runner = self.nixosConfigurations."${name}${flavor.suffix}-${system}".config.microvm.runner.qemu;
        in mkRunnerScript { inherit pkgs runner; inherit (flavor) dataDirName apiKeyVars; agentName = name; }) vmFlavors
      );
    };
}
