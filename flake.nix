{
  description = "Claude Code microVM";

  # microvm.nix's `optimize.enable` builds QEMU as
  # qemu_kvm.override { nixosTestRunner = true; } — a hostCpuOnly +
  # nixosTestRunner combination that Hydra stopped building when nixpkgs
  # dropped hostCpuOnly from qemu_test (NixOS/nixpkgs#541354, 2026-07-21).
  # It is absent from cache.nixos.org, so without these caches every user
  # compiles QEMU from source (~20 min) after each flake.lock bump.
  # See README "Binary caches" — these are opt-in; Nix ignores them (or
  # prompts) unless you are a trusted user.
  nixConfig = {
    extra-substituters = [
      "https://systemstart.cachix.org"
      "https://microvm.cachix.org"
    ];
    extra-trusted-public-keys = [
      "systemstart.cachix.org-1:hSTfDlXstyuVVukogR0sEmt8wJsaplp7NvisgUugNpE="
      "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys="
    ];
  };

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
        pi     = { suffix = "-pi";    agentModule = ./modules/agents/pi.nix;    dataDirName = "pi-microvm";    apiKeyVars = [ "ANTHROPIC_API_KEY" "OPENAI_API_KEY" "GEMINI_API_KEY" ]; };
      };

      mkRunnerScript = { pkgs, runner, dataDirName, apiKeyVars, agentName, defaultMem, defaultVcpu, defaultCriSize, storeDiskBacked, defaultStoreSize }:
        let
          virtiofsd = pkgs.virtiofsd;
          hostname = "${agentName}-vm";
          apiKeyForwarding = lib.concatStringsSep "\n" (map (var:
            ''[ -n "''${${var}:-}" ] && echo "${var}=''${${var}}" >> "$AGENT_DIR/.microvm-env"''
          ) apiKeyVars);
        in pkgs.writeShellScriptBin "microvm-run" ''
        set -euo pipefail
        WORK="$(realpath "''${WORK_DIR:-$(pwd)}")"
        VM_MEM="''${VM_MEM:-${toString defaultMem}}"
        VM_VCPU="''${VM_VCPU:-${toString defaultVcpu}}"
        CRI_STORAGE_SIZE="''${CRI_STORAGE_SIZE:-${toString defaultCriSize}}"
        ${lib.optionalString storeDiskBacked ''VM_STORE_SIZE="''${VM_STORE_SIZE:-${toString defaultStoreSize}}"''}
        RUNTIME="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        ID="$(cat /proc/sys/kernel/random/uuid)"

        # Volume size knobs are integers in MiB. Validate before QEMU sees them:
        # a bad value otherwise surfaces as a mkfs failure or, worse, a store
        # too small to hold a dev shell — which looks like a Nix bug from inside
        # the guest.
        if ! [[ "$CRI_STORAGE_SIZE" =~ ^[0-9]+$ ]]; then
          echo "error: CRI_STORAGE_SIZE must be an integer in MiB (0 disables the disk)" >&2
          exit 1
        fi
        if [ "$CRI_STORAGE_SIZE" -ne 0 ] && [ "$CRI_STORAGE_SIZE" -lt 1024 ]; then
          echo "error: CRI_STORAGE_SIZE must be at least 1024 MiB, or 0 to run without container storage" >&2
          exit 1
        fi
        if [ "$CRI_STORAGE_SIZE" -eq 0 ] && [ -n "''${ENABLE_CRI:-}" ]; then
          echo "warning: CRI_STORAGE_SIZE=0 with ENABLE_CRI=''${ENABLE_CRI} — container storage will" >&2
          echo "         fall back to the VM's RAM-backed rootfs. Image pulls will consume memory," >&2
          echo "         and layer unpack may fail on ownership. Unset CRI_STORAGE_SIZE to get a disk." >&2
        fi${lib.optionalString storeDiskBacked ''

        if ! [[ "$VM_STORE_SIZE" =~ ^[0-9]+$ ]] || [ "$VM_STORE_SIZE" -lt 1024 ]; then
          echo "error: VM_STORE_SIZE must be an integer of at least 1024 (MiB)." >&2
          echo "       Unlike CRI_STORAGE_SIZE, 0 is not accepted: the writable store is mounted" >&2
          echo "       in the initrd and /nix/store's overlay requires it, so a missing disk is a" >&2
          echo "       failed boot, not a fallback to RAM. Build with claude-vm.store.diskBacked" >&2
          echo "       = false for the RAM-backed store (see README)." >&2
          exit 1
        fi''}

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

        # --- CRI storage volume (ext4 block image) ---
        # Container runtimes need a real block-backed fs that permits lchown to
        # arbitrary UIDs during image unpack — a virtiofs share cannot (rootless
        # virtiofsd has a single-ID uid map). The image is a sparse ext4 disk
        # created on first boot by microvm.nix's createVolumesScript. It must NOT
        # live inside $AGENT_DIR: that directory is exported into the guest via
        # the agent-home virtiofs share, so the guest could read or tamper with
        # its own raw storage backing file. Keep it in a host-only sibling state
        # dir that persists across runs but is never shared into the guest. The
        # CRI module declares the image as "cri-storage.img"; rewrite it to this
        # absolute path below.
        # Whether to attach the container storage disk at all. The guest's mount
        # for it carries `nofail`, so a launch without the drive boots fine and
        # /var/lib/containers stays an ordinary directory.
        #
        #   CRI_STORAGE_SIZE=0   never — explicit opt-out, even for CRI runs
        #   ENABLE_CRI set       yes, creating the image if it does not exist
        #   ENABLE_CRI empty     only if the image already exists
        #
        # The last rule is what keeps this honest in both directions. A user who
        # never touches containers never gets a ~133 MiB image they did not ask
        # for; a user who has one keeps it attached on every launch, so a run
        # without ENABLE_CRI cannot make an existing image cache or KinD cluster
        # look like it evaporated — and starting a runtime by hand still finds a
        # real disk rather than silently writing to RAM.
        #
        # Nothing here ever deletes the image: detaching is reversible, deleting
        # is not.
        CRI_STATE_DIR="$AGENT_DIR-cri"
        CRI_IMG="$CRI_STATE_DIR/cri-storage.img"
        CRI_ATTACH=1
        if [ "$CRI_STORAGE_SIZE" -eq 0 ]; then
          CRI_ATTACH=0
        elif [ -z "''${ENABLE_CRI:-}" ] && [ ! -e "$CRI_IMG" ]; then
          CRI_ATTACH=0
        fi
        if [ "$CRI_ATTACH" -eq 1 ]; then
          mkdir -p "$CRI_STATE_DIR"
        fi

        ${lib.optionalString storeDiskBacked ''
        # --- Writable /nix/store overlay volume (ext4 block image) ---
        # The guest's writable store lives on this disk rather than on its
        # RAM-backed rootfs: `nix develop` snapshots the whole working tree into
        # the store whenever a flake input is a dirty git worktree, and a day of
        # those fills tmpfs and takes the VM down with ENOSPC. Host-only sibling
        # dir for the same reason as the CRI image — never exported through the
        # agent-home share, so the guest cannot reach its own backing file.
        #
        # Deliberately recreated empty on every launch. The guest imports a
        # snapshot of the *host's* nix DB at boot, which knows nothing about
        # paths a previous run built, so a persistent image would accumulate
        # store paths that nix considers invalid and never reuses — and it would
        # break the documented "restart the VM to get a clean store" escape
        # hatch. A VM still running off this image keeps its own open fd, so the
        # unlink below does not disturb it.
        STORE_STATE_DIR="$AGENT_DIR-store"
        mkdir -p "$STORE_STATE_DIR"
        STORE_IMG="$STORE_STATE_DIR/nix-store-overlay.img"
        rm -f "$STORE_IMG"
        ''}

        cleanup() {
          ${pkgs.systemd}/bin/systemctl --user stop "$UNIT" 2>/dev/null || true
          ${pkgs.systemd}/bin/systemctl --user stop "$AGENT_UNIT" 2>/dev/null || true
          rm -f "$SOCK" "$AGENT_SOCK" "$STATE" "$AGENT_STATE"
          ${lib.optionalString storeDiskBacked ''rm -f "$STORE_IMG"
          # Leave nothing behind on the host: the dir is ours and the image is
          # gone, so drop it unless something else put files there.
          rmdir "$STORE_STATE_DIR" 2>/dev/null || true''}
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

        # Write host env vars for the VM
        echo "DIRENV_ALLOW=''${DIRENV_ALLOW:-0}" > "$AGENT_DIR/.microvm-env"
        # The file carries API keys and whatever EXTRA_ENV forwards, and it
        # lives in the agent data dir on the host — keep it owner-only.
        chmod 600 "$AGENT_DIR/.microvm-env"
        echo "ENABLE_CRI=''${ENABLE_CRI:-}" >> "$AGENT_DIR/.microvm-env"
        # %q produces a single-quoted/escaped form that survives `source`
        # so values like AGENTS_ARGS='-p "hi there"' round-trip intact.
        printf 'AGENTS_ARGS=%q\n' "''${AGENTS_ARGS:-}" >> "$AGENT_DIR/.microvm-env"
        ${apiKeyForwarding}

        # Forward arbitrary host env vars into the guest, comma-separated:
        #   EXTRA_ENV="FOO=bar,HTTPS_PROXY"
        # An entry containing '=' is a literal assignment; a bare name forwards
        # that variable's value from the host environment, which keeps secrets
        # off the command line (where `ps` exposes them) and out of shell
        # history. Written last, so an entry here overrides an earlier key.
        if [ -n "''${EXTRA_ENV:-}" ]; then
          _OLD_IFS="$IFS"
          IFS=','
          read -r -a _EXTRA_ENV_ENTRIES <<< "$EXTRA_ENV"
          IFS="$_OLD_IFS"
          for _entry in ''${_EXTRA_ENV_ENTRIES+"''${_EXTRA_ENV_ENTRIES[@]}"}; do
            # `read` into a single variable strips surrounding whitespace, so
            # "FOO=1, BAR=2 , BAZ" forwards BAR as "2", not "2 ". Whitespace
            # inside a value is preserved.
            read -r _entry <<< "$_entry" || true
            [ -z "$_entry" ] && continue
            # Split on the first '=' — everything after it is the value, so
            # values may contain '=' themselves.
            _name="''${_entry%%=*}"
            if ! [[ "$_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
              echo "warning: EXTRA_ENV: invalid variable name '$_name', skipping"
              continue
            fi
            if [[ "$_entry" != *=* ]]; then
              if [ -z "''${!_name+set}" ]; then
                echo "warning: EXTRA_ENV: $_name is not set on the host, skipping"
                continue
              fi
              _value="''${!_name}"
            else
              _value="''${_entry#*=}"
            fi
            # %q again: the guest sources this file, so an unescaped value
            # would be executable code, not data.
            printf '%s=%q\n' "$_name" "$_value" >> "$AGENT_DIR/.microvm-env"
          done
        fi

        # Copy custom CA certificates into agent home for the VM
        if [ -n "''${EXTRA_CA_CERTS:-}" ]; then
          _CA_DIR="$AGENT_DIR/.microvm-ca-certs"
          rm -rf "$_CA_DIR"
          mkdir -p "$_CA_DIR"
          if [ -f "$EXTRA_CA_CERTS" ]; then
            cp "$EXTRA_CA_CERTS" "$_CA_DIR/"
          elif [ -d "$EXTRA_CA_CERTS" ]; then
            find "$EXTRA_CA_CERTS" -maxdepth 1 -type f \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' \) -exec cp {} "$_CA_DIR/" \;
          else
            echo "warning: EXTRA_CA_CERTS=$EXTRA_CA_CERTS is not a file or directory, ignoring"
          fi
          if [ -d "$_CA_DIR" ] && [ -z "$(ls -A "$_CA_DIR" 2>/dev/null)" ]; then
            echo "warning: no certificate files found in EXTRA_CA_CERTS=$EXTRA_CA_CERTS"
            rm -rf "$_CA_DIR"
          fi
        fi

        # Pre-cache dev shell environment on host (fast) so the VM doesn't have to evaluate nix
        _DEVSHELL_CACHE="$AGENT_DIR/.microvm-devshell"
        # The file tests must be grouped: `A && B || C` parses as `(A && B) || C`,
        # which would run `nix print-dev-env` on the host against an untrusted
        # $WORK whenever a marker file exists, even with DIRENV_ALLOW unset.
        #
        # devenv.nix is the marker for a devenv project: it is what `devenv init`
        # writes and what gets committed. .devenv.flake.nix is generated state —
        # devenv's own .gitignore starts with `.devenv*`, and it does not exist
        # until a first build — so it stays as a fallback for older layouts
        # rather than as the thing detection depends on. See issue #19.
        if [ "''${DIRENV_ALLOW:-0}" = "1" ] && { [ -f "$WORK/flake.nix" ] || [ -f "$WORK/devenv.nix" ] || [ -f "$WORK/.devenv.flake.nix" ]; }; then
          _CURRENT_HASH="$( (cat "$WORK/flake.nix" "$WORK/flake.lock" "$WORK/.devenv.flake.nix" "$WORK/devenv.nix" "$WORK/devenv.yaml" "$WORK/devenv.lock" 2>/dev/null || true) | sha256sum | cut -c1-16)"
          _CACHED_HASH=""
          [ -f "$_DEVSHELL_CACHE.hash" ] && _CACHED_HASH="$(cat "$_DEVSHELL_CACHE.hash")"
          if [ "$_CURRENT_HASH" != "$_CACHED_HASH" ] || [ ! -s "$_DEVSHELL_CACHE" ]; then
            echo "caching dev shell environment..."
            # No flake.nix at the top level means there is nothing for
            # `nix print-dev-env` to evaluate, whichever devenv files are present.
            if ! [ -f "$WORK/flake.nix" ]; then
              _CACHE_CMD="devenv print-dev-env"
              if ! command -v devenv >/dev/null 2>&1; then
                echo "warning: $WORK is a devenv project, but devenv is not on PATH — the dev shell will not be available in the VM"
              fi
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
              echo "warning: could not cache the dev shell; see ~/.microvm-devshell.err in the VM"
            fi
          fi
        elif [ "''${DIRENV_ALLOW:-0}" = "1" ]; then
          echo "warning: DIRENV_ALLOW=1 but $WORK has no flake.nix or devenv.nix — no dev shell to load"
        fi

        # Snapshot host's nix store DB so the VM's DB knows about every path
        # visible via the /nix/.ro-store overlay lowerdir. Without this, the VM
        # treats host-provided paths as missing and substitutes them — copying
        # bytes that already exist on disk into the tmpfs upperdir.
        #
        # Plain `.backup` restarts from page 1 whenever the source db is
        # written by another connection (e.g. nix-daemon) mid-copy. On an
        # active host this can loop indefinitely, burning CPU without making
        # progress. Opening an explicit read transaction first pins a
        # snapshot on the same connection that runs the backup, so external
        # commits during the backup no longer invalidate copied pages.
        # See: https://sqlite.org/forum/info/cca839708d74a20014f7188b86a19b267602d497bfa90ec1d1e79111a5b24adb
        if [ -f /nix/var/nix/db/db.sqlite ]; then
          ${pkgs.sqlite}/bin/sqlite3 /nix/var/nix/db/db.sqlite \
            ".timeout 30000" \
            "BEGIN;" \
            "SELECT count(*) FROM sqlite_master;" \
            ".backup '$AGENT_DIR/.microvm-nix-db.sqlite'" \
            "COMMIT;" \
            > /dev/null \
            || rm -f "$AGENT_DIR/.microvm-nix-db.sqlite"
        fi

        # $CRI_IMG is used as sed replacement text below. Escape characters
        # that are special on the replacement side (\, &) and the | delimiter
        # so a path with such characters can't corrupt the generated command.
        _CRI_IMG_ESC=$(printf '%s' "$CRI_IMG" | ${pkgs.gnused}/bin/sed -e 's/[\\&|]/\\&/g')
        ${lib.optionalString storeDiskBacked ''_STORE_IMG_ESC=$(printf '%s' "$STORE_IMG" | ${pkgs.gnused}/bin/sed -e 's/[\\&|]/\\&/g')''}

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
          # CRI storage volume image: microvm.nix emits the relative path
          # "cri-storage.img" in both the createVolumesScript and the QEMU
          # -drive; point both at the persistent image in agent home.
          -e "s|cri-storage.img|$_CRI_IMG_ESC|g"${lib.optionalString storeDiskBacked ''

          # Writable store volume size (VM_STORE_SIZE env var, MiB). Runs before
          # the image path is rewritten below, so it can anchor on the image name
          # and cannot be confused with the CRI volume's truncate line — sed
          # applies -e expressions in order.
          -e "s|truncate -s ${toString defaultStoreSize}M 'nix-store-overlay.img'|truncate -s ''${VM_STORE_SIZE}M 'nix-store-overlay.img'|g"
          # Writable store volume image: as for the CRI image, microvm.nix emits
          # the relative "nix-store-overlay.img" in both the createVolumesScript
          # and the QEMU -drive.
          -e "s|nix-store-overlay.img|$_STORE_IMG_ESC|g"''}
          # CRI storage volume size (CRI_STORAGE_SIZE env var, MiB). microvm.nix
          # emits `truncate -s <size>M` inside an `[ ! -e <image> ]` guard, so
          # this sizes a freshly created image only: an existing one keeps the
          # size it was made with, and growing it means resize2fs or deleting
          # the image (see README "Container runtime support").
          -e "s|truncate -s ${toString defaultCriSize}M|truncate -s ''${CRI_STORAGE_SIZE}M|g"
          # microvm.nix unconditionally sets cache=none (O_DIRECT) on volume
          # drives, which fails when agent home is on a filesystem without
          # O_DIRECT support (tmpfs, some network/virtiofs mounts). The CRI
          # store is a rebuildable cache, so writeback (host page cache) is the
          # portable choice and works on every backing filesystem.
          -e "s|,cache=none|,cache=writeback|g"
          # Runtime mem/vcpu override (VM_MEM / VM_VCPU env vars).
          # microvm.nix emits `-m <mem>M`, so the M must be part of the pattern:
          # without it the -m substitution silently misses while the memfd
          # `size=` below still changes, and QEMU refuses to start with
          # "total memory for NUMA nodes should equal RAM size".
          -e "s| -m ${toString defaultMem}M | -m ''${VM_MEM}M |g"
          -e "s| -smp ${toString defaultVcpu} | -smp $VM_VCPU |g"
          -e "s|size=${toString defaultMem}M|size=''${VM_MEM}M|g"
        )

        # Dropping the CRI disk is a deletion rather than a rewrite, and it runs
        # after the substitutions above, so both patterns have to tolerate the
        # image path already being absolute — hence `[^']*cri-storage\.img`
        # rather than an anchor on the relative name. Keyed on the image name
        # and not on the drive letter, which shifts with the volume order.
        if [ "$CRI_ATTACH" -eq 0 ]; then
          _SED_ARGS+=(
            # The `if [ ! -e … ]; then … fi` block that would create the image.
            -e "/^if \[ ! -e '[^']*cri-storage\.img' \]; then$/,/^fi$/d"
            # The drive and the virtio-blk device that exposes it.
            -e "s|-drive '[^']*cri-storage\.img[^']*' -device '[^']*' ||g"
          )
        fi

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
          nixosCfg = self.nixosConfigurations."${name}${flavor.suffix}-${system}".config;
          runner = nixosCfg.microvm.runner.qemu;
        in mkRunnerScript {
          inherit pkgs runner;
          inherit (flavor) dataDirName apiKeyVars;
          agentName = name;
          defaultMem = nixosCfg.claude-vm.agent.mem;
          defaultVcpu = nixosCfg.claude-vm.agent.vcpu;
          defaultCriSize = nixosCfg.claude-vm.cri.storageSize;
          storeDiskBacked = nixosCfg.claude-vm.store.diskBacked;
          defaultStoreSize = nixosCfg.claude-vm.store.size;
        }) vmFlavors
      );

      # Picked up by the `nix flake check --impure` already in CI, so these run
      # without any workflow change. nixosTest boots a VM and drives it as root,
      # which is the only way to exercise guest hardening: inside a live
      # claude-vm the agent user is denied sudo, and the host-side launch path
      # is not reachable from in there at all.
      checks = forSystems (system: let pkgs = nixpkgs.legacyPackages.${system}; in {
        module-hardening = import ./tests/module-hardening.nix { inherit pkgs; };
        store-overlay-disk = import ./tests/store-overlay-disk.nix {
          inherit pkgs lib;
          config = self.nixosConfigurations."claude-${system}".config;
        };
        share-recovery = import ./tests/share-recovery.nix {
          inherit pkgs lib;
          config = self.nixosConfigurations."claude-${system}".config;
        };
        seed-idempotence = import ./tests/seed-idempotence.nix {
          inherit pkgs lib;
          config = self.nixosConfigurations."claude-${system}".config;
        };
      });
    };
}
