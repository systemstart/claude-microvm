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
    # The egress/workspace policy layer: guest modules (sealed egress,
    # workspace write-guard, ephemeral mode), the host-side egress proxy and
    # egress-report, and the generic allowlist. This flake keeps only the
    # consumer glue — the launcher and the agent-specific allowlists.
    microvm-policy = {
      url = "github:systemstart/microvm-policy/v0.3.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, microvm, microvm-policy }:
    let
      lib = nixpkgs.lib;
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];
      forSystems = lib.genAttrs linuxSystems;

      vmFlavors = {
        claude = { suffix = "";        agentModule = ./modules/agents/claude.nix; dataDirName = "claude-microvm"; apiKeyVars = [ "ANTHROPIC_API_KEY" ]; settingsFile = ".claude/settings.json"; egressAllowlists = [ ./modules/egress/allowlist-claude.txt ]; };
        gemini = { suffix = "-gemini"; agentModule = ./modules/agents/gemini.nix; dataDirName = "gemini-microvm"; apiKeyVars = [ "GEMINI_API_KEY" ]; settingsFile = ".gemini/settings.json"; egressAllowlists = [ ./modules/egress/allowlist-gemini.txt ]; };
        codex  = { suffix = "-codex";  agentModule = ./modules/agents/codex.nix;  dataDirName = "codex-microvm";  apiKeyVars = [ "OPENAI_API_KEY" ]; settingsFile = ".codex/config.toml"; egressAllowlists = [ ./modules/egress/allowlist-codex.txt ]; };
        pi     = { suffix = "-pi";    agentModule = ./modules/agents/pi.nix;    dataDirName = "pi-microvm";    apiKeyVars = [ "ANTHROPIC_API_KEY" "OPENAI_API_KEY" "GEMINI_API_KEY" ]; settingsFile = null; egressAllowlists = [ ./modules/egress/allowlist-claude.txt ./modules/egress/allowlist-gemini.txt ./modules/egress/allowlist-codex.txt ]; };
      };

      # Reverse-proxied LLM endpoints per flavor, consumed by the
      # shadow/enforce wiring below: the guest's <baseUrlVar> points at
      # <prefix> on the proxy, which strips client-supplied credentials and
      # injects $<keyVar> as <header> upstream — or passes the client's own
      # token through when the var is unset on the host (OAuth mode).
      # allowedPaths is a per-host capability grant; shadow mode's audit log
      # is how it gets extended when a client needs more.
      egressEndpoints = rec {
        claude = [ { prefix = "/anthropic"; upstream = "https://api.anthropic.com"; keyVar = "ANTHROPIC_API_KEY"; header = "x-api-key"; baseUrlVar = "ANTHROPIC_BASE_URL"; allowedPaths = [ "/v1/messages" ]; } ];
        gemini = [ { prefix = "/gemini"; upstream = "https://generativelanguage.googleapis.com"; keyVar = "GEMINI_API_KEY"; header = "x-goog-api-key"; baseUrlVar = "GOOGLE_GEMINI_BASE_URL"; allowedPaths = [ "/v1beta/models" "/v1/models" ]; } ];
        codex  = [ { prefix = "/openai"; upstream = "https://api.openai.com"; keyVar = "OPENAI_API_KEY"; header = "authorization"; baseUrlVar = "OPENAI_BASE_URL"; allowedPaths = [ "/v1/responses" "/v1/chat/completions" "/v1/models" ]; } ];
        pi = claude ++ gemini ++ codex;
      };

      # Where the guest reaches the proxy: a slirp-internal address that
      # guestfwd maps onto the host-side listener. Chosen to dodge 10.0.2.2
      # (host), 10.0.2.3 (DNS) and 10.0.2.15 (guest). microvm-policy's
      # egress module ssh wrapper learns it from EGRESS_PROXY_ADDR in the
      # launcher's env file.
      egressGuestAddr = "10.0.2.100:3128";

      # Stops a running launch from outside the VM by pressing its power button
      # over QMP; flavor-independent, since every launch's instance dir is
      # under the same root. See scripts/microvm-stop.sh.
      mkMicrovmStop = pkgs: pkgs.writeShellApplication {
        name = "microvm-stop";
        runtimeInputs = with pkgs; [ coreutils gnugrep jq socat util-linux ];
        text = builtins.readFile ./scripts/microvm-stop.sh;
      };

      mkRunnerScript = { pkgs, runner, dataDirName, apiKeyVars, agentName, settingsFile, defaultMem, defaultVcpu, defaultCriSize, storeDiskBacked, defaultStoreSize, egressReport, egressAllowlistSources, egressProxy, flavorEndpoints }:
        let
          virtiofsd = pkgs.virtiofsd;
          hostname = "${agentName}-vm";
          apiKeyForwarding = lib.concatStringsSep "\n" (map (var:
            ''[ -n "''${${var}:-}" ] && echo "${var}=''${${var}}" >> "$INSTANCE_ENV"''
          ) apiKeyVars);
          # Bash fragments for the shadow/enforce wiring, one per endpoint.
          # keyEnv is decided at launch: the var's presence on the host picks
          # between injection and OAuth passthrough.
          egressEndpointJson = lib.concatMapStringsSep "\n" (ep: ''
            _EGRESS_EP_KEYENV=""
            if [ -n "''${${ep.keyVar}:-}" ]; then _EGRESS_EP_KEYENV="${ep.keyVar}"; fi
            _EGRESS_EPS="$_EGRESS_EPS,{\"prefix\":\"${ep.prefix}\",\"upstream\":\"${ep.upstream}\",\"keyEnv\":\"$_EGRESS_EP_KEYENV\",\"header\":\"${ep.header}\",\"allowedPaths\":${lib.replaceStrings [ "\"" ] [ "\\\"" ] (builtins.toJSON ep.allowedPaths)}}"'') flavorEndpoints;
          egressProxySetenv = lib.concatMapStringsSep "\n" (ep: ''
            if [ -n "''${${ep.keyVar}:-}" ]; then _EGRESS_SETENV+=("--setenv=${ep.keyVar}"); fi'') flavorEndpoints;
          # Session-contract fragment: which credential vars the host holds,
          # names only — values never appear anywhere near a terminal.
          contractKeyChecks = lib.concatStringsSep "\n" (map (var: ''
            if [ -n "''${${var}:-}" ]; then _CONTRACT_KEYS="$_CONTRACT_KEYS ${var}"; fi'') apiKeyVars);
          egressGuestEnv = lib.concatMapStringsSep "\n" (ep: ''
            echo "${ep.baseUrlVar}=http://${egressGuestAddr}${ep.prefix}" >> "$INSTANCE_ENV"
            if [ -n "''${${ep.keyVar}:-}" ]; then
              # Clients insist on a key being present; the proxy strips and
              # replaces whatever travels, so a placeholder satisfies them
              # and the real key never enters the guest.
              echo "${ep.keyVar}=egress-proxy-placeholder" >> "$INSTANCE_ENV"
            fi'') flavorEndpoints;
          launcher = pkgs.writeShellScriptBin "microvm-run" ''
        set -euo pipefail
        WORK="$(realpath "''${WORK_DIR:-$(pwd)}")"
        # Derive project basename for host-visible identifiers
        WORK_BASENAME="$(basename "$WORK" | tr -cd 'a-zA-Z0-9_-' | head -c 12)"
        [ -z "$WORK_BASENAME" ] && WORK_BASENAME="root"
        VM_ID="$WORK_BASENAME-${hostname}"

        # --- Launch scope and slice ---
        # Every systemd --user unit of a launch shares one stem,
        # claude_microvm-<id>, and sits in its own slice of that name, nested
        # in claude_microvm.slice (a dash in a slice name is a level of
        # nesting, hence the underscore before it):
        #
        #   claude_microvm.slice
        #     claude_microvm-<id>.slice           this launch
        #       claude_microvm-<id>.scope         the launcher, and QEMU
        #       claude_microvm-<id>-work.service        virtiofsd for /work
        #       claude_microvm-<id>-agent-home.service  virtiofsd for agent home
        #       claude_microvm-<id>-guest.service       virtiofsd for the guest share
        #       claude_microvm-<id>-egress.service      EGRESS_POLICY=alert|shadow|enforce
        #
        # Unit names are global to the user manager, so the slice does not
        # namespace them: the ID keeps them apart, and each unit's description
        # says what it is and for which project. `systemctl --user status
        # claude_microvm-<id>.slice` shows a launch and `systemctl --user stop`
        # on it stops one. The slice is made on first use and, once empty,
        # stays until logout — instance.json and its lock, not the slice, say
        # whether a launch is live.
        #
        # The launcher re-runs itself, once, in the scope. QEMU runs as its
        # child, so the scope holds the VM's processes for as long as any of
        # them lives, and every daemon is bound to it (BindsTo= + After=): if
        # the launcher is killed outright, the trap that would stop them never
        # runs, but systemd stops them as soon as the scope empties — and not
        # before, since QEMU outliving the launcher means the VM still runs.
        # systemd-run --scope runs the command in this same process, so the
        # terminal, the environment and the PID carry over; the ID is passed
        # along so the units and the instance dir share it.
        #
        # The scope can be refused: systemd-run has to move this process into
        # the user manager's cgroups, which systemd 261 allows from a login
        # session and even from a system service, but other versions and
        # setups may not. A probe scope finds out first; without one the
        # launch goes ahead unbound, and says so. Its daemons still get the
        # slice.
        _DESCRIBE=${lib.escapeShellArg "${agentName} microvm"}
        if [ -z "''${_MICROVM_SCOPE:-}" ]; then
          # The launch ID: 12 hex digits, 48 random bits — unique enough among
          # one user's launches (and mkdir refuses a clash rather than sharing
          # an instance dir), and short enough that its socket paths fit; a
          # whole UUID pushed them past the limit. The first 12 hex digits of a
          # v4 UUID are all random.
          _MICROVM_ID="$(cat /proc/sys/kernel/random/uuid)"
          _MICROVM_ID="''${_MICROVM_ID//-/}"; _MICROVM_ID="''${_MICROVM_ID:0:12}"
          if _SCOPE_ERR=$(${pkgs.systemd}/bin/systemd-run --user --scope --quiet --collect -- true 2>&1); then
            _MICROVM_SCOPE="claude_microvm-$_MICROVM_ID.scope"
            export _MICROVM_ID _MICROVM_SCOPE
            exec ${pkgs.systemd}/bin/systemd-run --user --scope --quiet --collect \
              --unit="$_MICROVM_SCOPE" --slice="claude_microvm-$_MICROVM_ID.slice" \
              --description="$_DESCRIBE $_MICROVM_ID: the VM, for $WORK" \
              -- "$0" "$@"
          fi
          echo "warning: cannot run this launch in a systemd --user scope: ''${_SCOPE_ERR:-systemd-run failed}" >&2
          echo "         continuing without one — if the launcher is killed outright, nothing stops its daemons" >&2
          _MICROVM_SCOPE=""
        elif ! [[ "''${_MICROVM_ID:-}" =~ ^[0-9a-f]{12}$ ]]; then
          echo "error: _MICROVM_SCOPE is set but _MICROVM_ID is not a launch ID (12 hex digits); unset both (they are the launcher's own)" >&2
          exit 1
        fi
        ID="$_MICROVM_ID"
        UNIT_STEM="claude_microvm-$ID"
        SLICE="$UNIT_STEM.slice"
        # Every daemon this launch starts: in its slice, tagged so
        # `journalctl MICROVM_ID=<id>` finds all of their logs, and bound to
        # the scope when there is one — BindsTo= a unit that does not exist
        # would stop them starting at all. Each call adds its own
        # --description, from describe().
        _UNIT_PROPS=(--slice="$SLICE" -p "LogExtraFields=MICROVM_ID=$ID")
        if [ -n "$_MICROVM_SCOPE" ]; then
          _UNIT_PROPS+=(-p "BindsTo=$_MICROVM_SCOPE" -p "After=$_MICROVM_SCOPE")
        fi
        describe () { printf -- '--description=%s %s: %s, for %s' "$_DESCRIBE" "$ID" "$1" "$WORK"; }

        VM_MEM="''${VM_MEM:-${toString defaultMem}}"
        VM_VCPU="''${VM_VCPU:-${toString defaultVcpu}}"
        CRI_STORAGE_SIZE="''${CRI_STORAGE_SIZE:-${toString defaultCriSize}}"
        ${lib.optionalString storeDiskBacked ''VM_STORE_SIZE="''${VM_STORE_SIZE:-${toString defaultStoreSize}}"''}
        RUNTIME="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

        # --- Egress policy (monitor / alert) ---
        # Passive observation of the guest's traffic via a QEMU filter-dump
        # object on the slirp netdev. Neither mode blocks anything; the
        # enforcing modes (shadow, enforce) arrive with the egress proxy —
        # see README "Egress policy". Validated up front so a typo cannot
        # launch an unobserved session the user believes is being watched.
        EGRESS_POLICY="''${EGRESS_POLICY:-open}"
        case "$EGRESS_POLICY" in
          open|monitor|alert|shadow|enforce) ;;
          *)
            echo "error: EGRESS_POLICY must be open, monitor, alert, shadow or enforce (got '$EGRESS_POLICY')" >&2
            exit 1 ;;
        esac
        case "$EGRESS_POLICY" in
          open|monitor)
            if [ -n "''${EGRESS_ALLOW:-}" ] || [ -n "''${EGRESS_ALLOWLIST:-}" ] || [ -n "''${EGRESS_DENY:-}" ]; then
              echo "warning: EGRESS_ALLOW / EGRESS_ALLOWLIST / EGRESS_DENY are only read by EGRESS_POLICY=alert|shadow|enforce — ignored" >&2
            fi ;;
        esac
        if ! [[ "''${EGRESS_PCAP_MAXLEN:-4096}" =~ ^[0-9]+$ ]]; then
          echo "error: EGRESS_PCAP_MAXLEN must be an integer (captured bytes per packet)" >&2
          exit 1
        fi
        WORKSPACE_MODE="''${WORKSPACE_MODE:-passthrough}"
        case "$WORKSPACE_MODE" in
          passthrough|ephemeral) ;;
          *)
            echo "error: WORKSPACE_MODE must be passthrough or ephemeral (got '$WORKSPACE_MODE')" >&2
            exit 1 ;;
        esac
        # virtiofsd's --cache policy for the /work share; the agent-home share
        # keeps the default. See README "Work share caching".
        WORK_CACHE="''${WORK_CACHE:-auto}"
        case "$WORK_CACHE" in
          auto|always|never|metadata) ;;
          *)
            echo "error: WORK_CACHE must be auto, always, never or metadata (got '$WORK_CACHE')" >&2
            exit 1 ;;
        esac
        EGRESS_DIR=""
        EGRESS_PCAP=""
        EGRESS_UNIT=""
        EGRESS_ALERTS=""
        EGRESS_AUDIT=""
        _EGRESS_ALLOWLIST_FILE=""
        _EGRESS_PORTFILE=""
        _EGRESS_PROXY_CFG=""
        _EGRESS_RULES=""
        _CONTRACT_EXTRA=""
        # Colour for the session contract: only on a terminal, and never with
        # NO_COLOR set (https://no-color.org).
        if [ -t 1 ] && [ -z "''${NO_COLOR:-}" ]; then
          _C_B=$'\e[1m' _C_D=$'\e[2m' _C_R=$'\e[31m' _C_G=$'\e[32m' _C_Y=$'\e[33m' _C_0=$'\e[0m'
        else
          _C_B="" _C_D="" _C_R="" _C_G="" _C_Y="" _C_0=""
        fi
        # Paths in the contract: $HOME shown as ~ to keep rows on screen. A
        # tail command keeps the ~ outside the quotes, so it still expands
        # when pasted.
        _tilde() { case "$1" in "$HOME"/*) printf '~/%s' "''${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }
        _tailf() { case "$1" in "$HOME"/*) printf "tail -f ~/'%s'" "''${1#"$HOME"/}" ;; *) printf "tail -f '%s'" "$1" ;; esac; }

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

        # --- Instance dir (per launch, in the runtime dir) ---
        # Everything this launch keeps for itself lives under one directory,
        # and every path below is derived from it:
        #
        #   $XDG_RUNTIME_DIR/claude-microvm/     one root for every flavor
        #     vms/<id>/                          this launch; 0700, sticky
        #       guest/                           its own --readonly virtiofsd → /run/microvm
        #         env  ca-certs/  nix-db.sqlite
        #       instance.json                    what this is, for tools that list VMs
        #       lock                             held for the launch's lifetime
        #       qmp.sock                         QEMU's control socket
        #       work.sock  agent-home.sock  guest.sock   the three virtiofsd
        #       egress.port  egress.json         EGRESS_POLICY=shadow|enforce
        #
        # The runtime dir rather than beside agent home: it is tmpfs, so the
        # env file's API keys never reach a disk, and if cleanup never runs (a
        # SIGKILL, a host crash) what is left goes at logout or reboot rather
        # than staying on disk; it is local and private to the user, where
        # agent home may be anywhere; and socket paths there stay well inside
        # the 107-byte limit. Only guest/ is exported, so the rest never
        # reaches the guest. The disk images stay beside agent home: they are
        # gigabytes.
        if [ ! -d "$RUNTIME" ]; then
          echo "error: no runtime directory: $RUNTIME does not exist (is XDG_RUNTIME_DIR set, with a user session?)" >&2
          exit 1
        fi
        INSTANCE_ROOT="$RUNTIME/claude-microvm"
        # Named by the launch ID alone, like every unit of the launch: a tool
        # with an ID has the path, with nothing to search or match. What the
        # launch is — project, flavor — is in its instance.json. vms/ leaves
        # the root free for what is not one VM's.
        INSTANCE_VMS="$INSTANCE_ROOT/vms"
        # Set only once this launch has created it, so cleanup removes exactly
        # what it made and never a directory it did not.
        INSTANCE_DIR=""
        _INSTANCE_PATH="$INSTANCE_VMS/$ID"
        INSTANCE_GUEST="$_INSTANCE_PATH/guest"
        INSTANCE_ENV="$INSTANCE_GUEST/env"
        QMP_SOCK="$_INSTANCE_PATH/qmp.sock"

        SOCK="$_INSTANCE_PATH/work.sock"
        UNIT="$UNIT_STEM-work"
        AGENT_SOCK="$_INSTANCE_PATH/agent-home.sock"
        AGENT_UNIT="$UNIT_STEM-agent-home"
        GUEST_SOCK="$_INSTANCE_PATH/guest.sock"
        GUEST_UNIT="$UNIT_STEM-guest"
        # sun_path is 108 bytes, NUL included. The longest default is
        # /run/user/<uid>/claude-microvm/vms/<id>/agent-home.sock, 62 bytes for
        # a 4-digit uid, leaving room for longer uids and runtime dirs;
        # tests/instance-share.nix checks a 7-digit uid's. A
        # runtime dir long enough to break it would otherwise surface as QEMU
        # or virtiofsd failing to bind, after the daemons before it had started.
        for _s in "$QMP_SOCK" "$SOCK" "$AGENT_SOCK" "$GUEST_SOCK"; do
          if [ "''${#_s}" -gt 107 ]; then
            echo "error: socket path too long (''${#_s} bytes, the limit is 107): $_s" >&2
            echo "       it is under XDG_RUNTIME_DIR=$RUNTIME; a shorter one avoids this" >&2
            exit 1
          fi
        done
        AGENT_TEMP=""
        STORE_IMG=""
        STORE_STATE_DIR=""

        # Installed before the first daemon starts, so a refusal anywhere below
        # (a bad AGENT_SETTINGS, say) cannot leave a virtiofsd running and
        # exporting a host directory with nothing to stop it. Everything it
        # touches is initialised above for that reason.
        # virtiofsd removes neither its socket nor its `<socket>.pid` when
        # stopped with SIGTERM, which is what `systemctl stop` sends; both are
        # in the instance dir, which goes last, after every daemon has stopped.
        cleanup() {
          ${pkgs.systemd}/bin/systemctl --user stop "$UNIT" 2>/dev/null || true
          ${pkgs.systemd}/bin/systemctl --user stop "$AGENT_UNIT" 2>/dev/null || true
          ${pkgs.systemd}/bin/systemctl --user stop "$GUEST_UNIT" 2>/dev/null || true
          if [ -n "$EGRESS_UNIT" ]; then
            ${pkgs.systemd}/bin/systemctl --user stop "$EGRESS_UNIT" 2>/dev/null || true
          fi
          # The summary report is the artifact that persists; the raw capture
          # goes unless the user asked to keep it.
          if [ -n "$EGRESS_PCAP" ] && [ -z "''${EGRESS_KEEP_PCAP:-}" ]; then
            rm -f "$EGRESS_PCAP"
          fi
          if [ -n "$STORE_IMG" ]; then
            rm -f "$STORE_IMG"
            # Leave nothing behind on the host: the dir is ours and the image is
            # gone, so drop it unless something else put files there.
            rmdir "$STORE_STATE_DIR" 2>/dev/null || true
          fi
          if [ -n "$AGENT_TEMP" ]; then
            rm -rf "$AGENT_TEMP"
          fi
          # This launch's instance dir goes with it: guest/ — env (API keys
          # included), CA certs, DB snapshot — and its sockets, lock and egress
          # files. Its finished files are read-only (see the guest share), so
          # they are made writable first. vms/ and the root stay, empty, until
          # logout: they are shared by concurrent launches, and removing them
          # here would race one that has just made sure they exist and is
          # about to create its own dir in them.
          if [ -n "$INSTANCE_DIR" ]; then
            chmod -R u+w "$INSTANCE_DIR" 2>/dev/null || true
            rm -rf "$INSTANCE_DIR"
          fi
        }
        trap cleanup EXIT
        # bash runs the EXIT trap on SIGTERM and SIGHUP too, which is what
        # `systemctl --user stop <scope>` and closing the terminal send.
        # Nothing runs it on SIGKILL; for that, the daemons are bound to the
        # launch scope (see "Launch scope").

        # Created before the first daemon, whose socket lives in it. The root
        # and vms/ may already exist (another launch); this launch's dir must
        # not, and mkdir without -p refuses if it does. Sticky, as the XDG spec
        # asks of runtime files that must survive its periodic clean-up of
        # anything untouched for six hours — a VM can run for days.
        mkdir -p "$INSTANCE_VMS"
        chmod 700 "$INSTANCE_ROOT" "$INSTANCE_VMS"
        mkdir -m 1700 "$_INSTANCE_PATH"
        INSTANCE_DIR="$_INSTANCE_PATH"
        mkdir -m 1700 "$INSTANCE_GUEST"
        # Held until this launch — QEMU included, which inherits the descriptor
        # — has gone, so a dir whose lock can be taken is one nobody is using.
        # Read-only once open: the descriptor keeps working, and the tools
        # that check it open it read-only.
        exec {_INSTANCE_LOCK_FD}>"$INSTANCE_DIR/lock"
        chmod 1400 "$INSTANCE_DIR/lock"
        ${pkgs.util-linux}/bin/flock -n "$_INSTANCE_LOCK_FD"

        # Every launch starts its own daemons: the unit and socket names carry
        # this launch's random $ID, so there is never one to reuse. The cleanup
        # trap stops them on exit, and systemd does if the launch scope empties
        # without it (see "Launch scope" above).
        #
        # virtiofsd runs unprivileged in a user namespace (--sandbox=namespace).
        # --uid-map / --gid-map: map host user to namespace root (single-entry, no /etc/subuid needed)
        # --translate-uid / --translate-gid: map guest uid/gid 1000 to namespace uid/gid 0 (= host user)
        ${pkgs.systemd}/bin/systemd-run --user --unit="$UNIT" --collect "''${_UNIT_PROPS[@]}" "$(describe "virtiofsd for /work")" \
          -- ${virtiofsd}/bin/virtiofsd \
            --socket-path="$SOCK" \
            --shared-dir="$WORK" \
            --sandbox=namespace \
            --uid-map ":0:$(id -u):1:" \
            --gid-map ":0:$(id -g):1:" \
            --translate-uid "map:1000:0:1" \
            --translate-gid "map:1000:0:1" \
            --socket-group="$(id -gn)" \
            --xattr \
            --cache="$WORK_CACHE"

        # Wait for socket
        for i in $(seq 1 50); do
          [ -S "$SOCK" ] && break
          sleep 0.1
        done
        [ -S "$SOCK" ] || { echo "error: virtiofsd socket did not appear"; exit 1; }

        # --- Agent home share (virtiofsd) ---
        if [ -z "''${AGENT_HOME:-}" ]; then
          DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
          WORK_HASH="$(echo -n "$WORK" | sha256sum | cut -c1-12)"
          AGENT_HOME="$DATA_HOME/${dataDirName}/$WORK_BASENAME-$WORK_HASH"
        fi
        AGENT_DIR="$(realpath "$AGENT_HOME" 2>/dev/null || echo "$AGENT_HOME")"
        if [ ! -d "$AGENT_DIR" ]; then
          mkdir -p "$AGENT_DIR"
        fi

        # What this instance is, for anything that lists running VMs: read
        # this rather than parsing the directory name. `units` are the
        # systemd --user units this launch starts; the egress one exists only
        # for the policies that run something on the host (the alert follower,
        # the shadow/enforce proxy), and is null otherwise.
        _EGRESS_UNIT_NAME=""
        case "$EGRESS_POLICY" in alert|shadow|enforce) _EGRESS_UNIT_NAME="$UNIT_STEM-egress" ;; esac
        ${pkgs.jq}/bin/jq -n \
          --argjson pid "$$" --arg flavor ${lib.escapeShellArg agentName} \
          --arg vmId "$VM_ID" --arg id "$ID" --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --arg work "$WORK" --arg agentHome "$AGENT_DIR" --arg guest "$INSTANCE_GUEST" \
          --arg egressPolicy "$EGRESS_POLICY" \
          --arg qmp "$QMP_SOCK" --arg workSock "$SOCK" --arg agentHomeSock "$AGENT_SOCK" --arg guestSock "$GUEST_SOCK" \
          --arg scopeUnit "$_MICROVM_SCOPE" --arg slice "$SLICE" \
          --arg workUnit "$UNIT" --arg agentHomeUnit "$AGENT_UNIT" --arg guestUnit "$GUEST_UNIT" --arg egressUnit "$_EGRESS_UNIT_NAME" \
          '{version: 1, pid: $pid, flavor: $flavor, vmId: $vmId, id: $id, started: $started,
            work: $work, agentHome: $agentHome, guest: $guest, guestMount: "/run/microvm",
            egressPolicy: $egressPolicy,
            sockets: {qmp: $qmp, work: $workSock, agentHome: $agentHomeSock, guest: $guestSock},
            slice: $slice,
            units: {scope: (if $scopeUnit == "" then null else $scopeUnit end), work: $workUnit, agentHome: $agentHomeUnit, guest: $guestUnit,
                    egress: (if $egressUnit == "" then null else $egressUnit end)}}' \
          > "$INSTANCE_DIR/instance.json.new"
        # Read-only, against accidental edits, and put in place whole, so a
        # tool never reads half of it. It describes the launch; the tools here
        # take nothing from it that the layout already says (the QMP socket is
        # always qmp.sock), and refuse one whose id is not its dir's name.
        chmod 1400 "$INSTANCE_DIR/instance.json.new"
        mv "$INSTANCE_DIR/instance.json.new" "$INSTANCE_DIR/instance.json"

        # What this launch hands the guest — the env file, EXTRA_CA_CERTS, the
        # nix DB snapshot — goes to the instance dir's guest/, not agent home.
        # Agent home is shared by every launch on the project and writable from
        # the guest, so files there were overwritten by the next launch and
        # could be rewritten by any of them, while root services in the guest
        # act on all three. Earlier launchers left them here, the env file with
        # API keys in it; nothing reads them here any more.
        rm -rf "$AGENT_DIR/.microvm-env" "$AGENT_DIR/.microvm-ca-certs" "$AGENT_DIR/.microvm-nix-db.sqlite"

        # --- Egress setup (EGRESS_POLICY != open) ---
        if [ "$EGRESS_POLICY" != "open" ]; then
          # Host-only sibling of the agent dir, like the CRI image: $AGENT_DIR
          # itself is exported into the guest, and the guest must not be able
          # to rewrite the record of its own traffic. Traffic metadata is
          # sensitive, so the directory is owner-only.
          EGRESS_DIR="$AGENT_DIR-egress"
          mkdir -p "$EGRESS_DIR"
          chmod 700 "$EGRESS_DIR"
          _EGRESS_STAMP="$(date +%Y%m%d-%H%M%S)-''${ID%%-*}"

          # Every non-open mode rewrites the QEMU command line, so the anchor
          # must exist. If microvm.nix ever changes the emitted netdev text,
          # fail loudly rather than silently launching unobserved or (worse)
          # unsealed — an unnoticed policy failure is exactly the failure
          # mode this feature exists to remove.
          if ! grep -qF -- "-netdev 'user,id=usernet'" ${runner}/bin/microvm-run; then
            echo "error: EGRESS_POLICY=$EGRESS_POLICY could not hook the QEMU command line:" >&2
            echo "       the generated runner no longer contains \"-netdev 'user,id=usernet'\"." >&2
            echo "       Launch with EGRESS_POLICY=open, and report this as a bug." >&2
            exit 1
          fi

          case "$EGRESS_POLICY" in monitor|alert)
            EGRESS_PCAP="$EGRESS_DIR/session-$_EGRESS_STAMP.pcap"
            # Pre-create the capture so the alert follower's tail -F starts
            # at byte 0 deterministically; QEMU's O_TRUNC open of the empty
            # file is a no-op.
            : > "$EGRESS_PCAP"
            _EGRESS_PCAP_ESC=$(printf '%s' "$EGRESS_PCAP" | ${pkgs.gnused}/bin/sed -e 's/[\\&|]/\\&/g')
          ;; esac

          case "$EGRESS_POLICY" in alert|shadow|enforce)
            # Effective allowlist = the built-in lists (common + flavor), plus
            # an optional org/project file, plus per-session additions, minus
            # EGRESS_DENY — assembled into one file so every consumer (the live
            # matcher, the final report, the proxy) sees the same list. Each
            # line is tagged with its source first, so the session contract
            # can show where every rule comes from and what overrode it.
            _EGRESS_ALLOWLIST_FILE="$EGRESS_DIR/session-$_EGRESS_STAMP.allowlist"
            _EGRESS_RULES="$_EGRESS_ALLOWLIST_FILE.rules"
            {
              ${lib.concatMapStrings (s: ''
              ${pkgs.gawk}/bin/awk -v l=${lib.escapeShellArg s.label} '{ print l "\t" $0 }' ${s.file}
              '') egressAllowlistSources}
              if [ -n "''${EGRESS_ALLOWLIST:-}" ]; then
                if [ ! -f "$EGRESS_ALLOWLIST" ]; then
                  echo "error: EGRESS_ALLOWLIST=$EGRESS_ALLOWLIST is not a file" >&2
                  exit 1
                fi
                ${pkgs.gawk}/bin/awk -v l="EGRESS_ALLOWLIST · $(_tilde "$EGRESS_ALLOWLIST")" '{ print l "\t" $0 }' "$EGRESS_ALLOWLIST"
              fi
              if [ -n "''${EGRESS_ALLOW:-}" ]; then
                printf '%s\n' "''${EGRESS_ALLOW//,/ }" | tr ' ' '\n' | ${pkgs.gawk}/bin/awk '{ print "EGRESS_ALLOW\t" $0 }'
              fi
            } > "$_EGRESS_RULES.src"
            ${pkgs.gawk}/bin/awk -f ${./scripts/egress-rules.awk} \
              -v deny="''${EGRESS_DENY:-}" -v mode="$EGRESS_POLICY" \
              -v allowout="$_EGRESS_ALLOWLIST_FILE" -v contractout="$_EGRESS_RULES" \
              -v B="$_C_B" -v D="$_C_D" -v R="$_C_R" -v G="$_C_G" -v Y="$_C_Y" -v Z="$_C_0" \
              "$_EGRESS_RULES.src"
            rm -f "$_EGRESS_RULES.src"
          ;; esac

          if [ "$EGRESS_POLICY" = "alert" ]; then
            EGRESS_ALERTS="$EGRESS_DIR/session-$_EGRESS_STAMP.alerts.log"
            : > "$EGRESS_ALERTS"
            # Stable name, because the session-stamped path printed at launch
            # scrolls away once the agent takes over the console.
            ln -sfn "$(basename "$EGRESS_ALERTS")" "$EGRESS_DIR/latest.alerts.log"
          fi

          case "$EGRESS_POLICY" in shadow|enforce)
            # The proxy is the only hole in the sealed netdev. It runs on the
            # host under the user's systemd, holds the API keys (passed by
            # name via --setenv, never on a command line), and writes one
            # JSONL line per decision.
            EGRESS_AUDIT="$EGRESS_DIR/session-$_EGRESS_STAMP.audit.jsonl"
            : > "$EGRESS_AUDIT"
            ln -sfn "$(basename "$EGRESS_AUDIT")" "$EGRESS_DIR/latest.audit.jsonl"
            _EGRESS_PORTFILE="$INSTANCE_DIR/egress.port"
            _EGRESS_PROXY_CFG="$INSTANCE_DIR/egress.json"
            _EGRESS_PROXY_MODE="enforce"
            [ "$EGRESS_POLICY" = "shadow" ] && _EGRESS_PROXY_MODE="log"
            # tests/egress-config.nix extracts the region between these
            # markers and feeds the result to the real egress-proxy binary,
            # so keep it self-contained on the _EGRESS_* variables above and
            # the per-endpoint lines generated at eval time.
            # BEGIN egress-proxy-config
            _EGRESS_EPS=""
            ${egressEndpointJson}
            cat > "$_EGRESS_PROXY_CFG" <<EOF
{"listen":"127.0.0.1:0","mode":"$_EGRESS_PROXY_MODE","allowlistFile":"$_EGRESS_ALLOWLIST_FILE","auditLog":"$EGRESS_AUDIT","portFile":"$_EGRESS_PORTFILE","endpoints":[''${_EGRESS_EPS#,}]}
EOF
            chmod 600 "$_EGRESS_PROXY_CFG"
            # END egress-proxy-config
            EGRESS_UNIT="$_EGRESS_UNIT_NAME"
            _EGRESS_SETENV=()
            ${egressProxySetenv}
            ${pkgs.systemd}/bin/systemd-run --user --unit="$EGRESS_UNIT" --collect "''${_UNIT_PROPS[@]}" "$(describe "egress proxy, EGRESS_POLICY=$EGRESS_POLICY")" \
              ''${_EGRESS_SETENV[@]+"''${_EGRESS_SETENV[@]}"} \
              -- ${egressProxy}/bin/egress-proxy -config "$_EGRESS_PROXY_CFG"
            for i in $(seq 1 50); do
              [ -s "$_EGRESS_PORTFILE" ] && break
              sleep 0.1
            done
            if [ ! -s "$_EGRESS_PORTFILE" ]; then
              echo "error: the egress proxy did not come up — see:" >&2
              echo "       journalctl --user -u $EGRESS_UNIT" >&2
              exit 1
            fi
            _EGRESS_PORT="$(cat "$_EGRESS_PORTFILE")"
            _EGRESS_PORT="''${_EGRESS_PORT##*:}"
          ;; esac
        fi

        # --- Agent settings seed ---
        ${if settingsFile != null then ''
        # AGENT_SETTINGS pre-seeds the agent's own config file into the agent
        # home before boot, so a fresh workspace starts with your settings
        # instead of the agent's defaults. Seed, not sync: the copy happens when
        # the destination is missing or when the *source* has changed since the
        # last seed (hash sidecar), so settings changed inside the VM persist
        # across launches until the host file moves — at which point the host
        # wins, whole-file. This is convenience, not enforcement: the guest can
        # rewrite the file mid-session like any other agent-home state.
        # tests/settings-seed.nix extracts the region between these markers and
        # drives it against fixtures; keep it self-contained on AGENT_SETTINGS,
        # AGENT_DIR and the tools in the runner closure.
        # BEGIN settings-seed
        if [ -n "''${AGENT_SETTINGS:-}" ]; then
          if [ ! -f "$AGENT_SETTINGS" ]; then
            echo "error: AGENT_SETTINGS=$AGENT_SETTINGS is not a file" >&2
            exit 1
          fi
          ${lib.optionalString (lib.hasSuffix ".json" settingsFile) ''
          # A malformed settings file would not fail loudly in the guest — the
          # agent just behaves as if unconfigured. Catch it before boot.
          if ! ${pkgs.jq}/bin/jq empty "$AGENT_SETTINGS" 2>/dev/null; then
            echo "error: AGENT_SETTINGS=$AGENT_SETTINGS is not valid JSON" >&2
            exit 1
          fi''}
          _SETTINGS_DEST="$AGENT_DIR/${settingsFile}"
          _SETTINGS_HASH="$(sha256sum < "$AGENT_SETTINGS" | cut -c1-16)"
          _SEEDED_HASH=""
          [ -f "$AGENT_DIR/.microvm-settings.hash" ] && _SEEDED_HASH="$(cat "$AGENT_DIR/.microvm-settings.hash")"
          if [ ! -f "$_SETTINGS_DEST" ] || [ "$_SETTINGS_HASH" != "$_SEEDED_HASH" ]; then
            if [ -f "$_SETTINGS_DEST" ] && [ -z "$_SEEDED_HASH" ]; then
              # The destination exists but was never seeded by us: it was
              # written inside a VM. Passing AGENT_SETTINGS says "use mine",
              # but destroying the only copy silently would be rude.
              cp "$_SETTINGS_DEST" "$_SETTINGS_DEST.pre-seed"
              echo "note: replacing existing ${settingsFile} (backup: ${settingsFile}.pre-seed)"
            fi
            mkdir -p "$(dirname "$_SETTINGS_DEST")"
            install -m 600 "$AGENT_SETTINGS" "$_SETTINGS_DEST"
            echo "$_SETTINGS_HASH" > "$AGENT_DIR/.microvm-settings.hash"
            echo "seeded ${settingsFile} from $AGENT_SETTINGS"
          fi
        fi
        # END settings-seed'' else ''
        if [ -n "''${AGENT_SETTINGS:-}" ]; then
          echo "warning: AGENT_SETTINGS is not supported for the ${agentName} flavor — ignored" >&2
        fi''}

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

        ${pkgs.systemd}/bin/systemd-run --user --unit="$AGENT_UNIT" --collect "''${_UNIT_PROPS[@]}" "$(describe "virtiofsd for agent home")" \
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

        for i in $(seq 1 50); do
          [ -S "$AGENT_SOCK" ] && break
          sleep 0.1
        done
        [ -S "$AGENT_SOCK" ] || { echo "error: agent-home virtiofsd socket did not appear"; exit 1; }

        # Write host env vars for the VM, into this launch's instance dir
        echo "DIRENV_ALLOW=''${DIRENV_ALLOW:-0}" > "$INSTANCE_ENV"
        # The file carries API keys and whatever EXTRA_ENV forwards — keep it
        # owner-only. In the guest it shows as the agent's, still 0600.
        chmod 600 "$INSTANCE_ENV"
        echo "ENABLE_CRI=''${ENABLE_CRI:-}" >> "$INSTANCE_ENV"
        # %q produces a single-quoted/escaped form that survives `source`
        # so values like AGENTS_ARGS='-p "hi there"' round-trip intact.
        printf 'AGENTS_ARGS=%q\n' "''${AGENTS_ARGS:-}" >> "$INSTANCE_ENV"
        # The guest reads the policy for the seal service and the ssh wrapper
        # (modules/egress.nix); it is informational in the open modes.
        echo "EGRESS_POLICY=$EGRESS_POLICY" >> "$INSTANCE_ENV"
        # Read by modules/workspace.nix: read-only binds over workspace paths
        # whose contents execute on the host later, and the ephemeral /work
        # overlay.
        echo "WORKSPACE_GUARD=''${WORKSPACE_GUARD:-}" >> "$INSTANCE_ENV"
        echo "WORKSPACE_MODE=$WORKSPACE_MODE" >> "$INSTANCE_ENV"
        case "$EGRESS_POLICY" in
          shadow|enforce)
            # The key never enters the guest: the agent talks plaintext HTTP
            # to the proxy over the guestfwd hop (which never leaves the
            # host), and the proxy originates genuine TLS upstream. NO_PROXY
            # keeps the BASE_URL requests origin-form instead of routing
            # them through the CONNECT handler.
            echo "EGRESS_PROXY_ADDR=${egressGuestAddr}" >> "$INSTANCE_ENV"
            # Negative control for the guest's seal self-test (microvm-policy
            # v0.3.0+): slirp maps 10.0.2.2 to the host's loopback, so without
            # restrict=on this reaches the proxy's host listener. Sealed, it
            # must be refused; with no probe the self-test fails inconclusive.
            echo "EGRESS_SEAL_PROBE=10.0.2.2:$_EGRESS_PORT" >> "$INSTANCE_ENV"
            for _v in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
              echo "$_v=http://${egressGuestAddr}" >> "$INSTANCE_ENV"
            done
            echo "NO_PROXY=${lib.head (lib.splitString ":" egressGuestAddr)},localhost,127.0.0.1" >> "$INSTANCE_ENV"
            echo "no_proxy=${lib.head (lib.splitString ":" egressGuestAddr)},localhost,127.0.0.1" >> "$INSTANCE_ENV"
            ${egressGuestEnv}
            ;;
          *)
            ${apiKeyForwarding}
            ;;
        esac

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
            printf '%s=%q\n' "$_name" "$_value" >> "$INSTANCE_ENV"
            _CONTRACT_EXTRA="$_CONTRACT_EXTRA $_name"
          done
        fi

        # Copy custom CA certificates into the instance dir for the VM
        if [ -n "''${EXTRA_CA_CERTS:-}" ]; then
          _CA_DIR="$INSTANCE_GUEST/ca-certs"
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
        if [ "''${DIRENV_ALLOW:-0}" = "1" ]; then
          # Detection only — no evaluation, no side effects, and reached only
          # with DIRENV_ALLOW=1, which is what keeps `nix print-dev-env` off an
          # untrusted $WORK. tests/devshell-detection.nix extracts the region
          # between these markers and drives it against fixture directories, so
          # keep it free of anything that touches the host.
          #
          # devenv.nix is the marker for a devenv project: it is what `devenv
          # init` writes and what gets committed. .devenv.flake.nix is generated
          # state — devenv's own .gitignore starts with `.devenv*`, and it does
          # not exist until a first build — so it stays as a fallback for older
          # layouts rather than as the thing detection depends on. See issue #19.
          # BEGIN devshell-detect
          _DEVSHELL_ELIGIBLE=0
          _CACHE_CMD=""
          if [ -f "$WORK/flake.nix" ] || [ -f "$WORK/devenv.nix" ] || [ -f "$WORK/.devenv.flake.nix" ]; then
            _DEVSHELL_ELIGIBLE=1
            # No flake.nix at the top level means there is nothing for
            # `nix print-dev-env` to evaluate, whichever devenv files are present.
            if ! [ -f "$WORK/flake.nix" ]; then
              _CACHE_CMD="devenv print-dev-env"
            elif [ -f "$WORK/devenv.nix" ]; then
              _CACHE_CMD="nix print-dev-env --no-update-lock-file --impure $WORK"
            else
              _CACHE_CMD="nix print-dev-env --no-update-lock-file $WORK"
            fi
          fi
          # END devshell-detect

          if [ "$_DEVSHELL_ELIGIBLE" = "0" ]; then
            echo "warning: DIRENV_ALLOW=1 but $WORK has no flake.nix or devenv.nix — no dev shell to load"
          else
            _CURRENT_HASH="$( (cat "$WORK/flake.nix" "$WORK/flake.lock" "$WORK/.devenv.flake.nix" "$WORK/devenv.nix" "$WORK/devenv.yaml" "$WORK/devenv.lock" 2>/dev/null || true) | sha256sum | cut -c1-16)"
            _CACHED_HASH=""
            [ -f "$_DEVSHELL_CACHE.hash" ] && _CACHED_HASH="$(cat "$_DEVSHELL_CACHE.hash")"
            # The guest can write /work, so Nix files changed since the last
            # evaluation may have been edited by the agent — and this cache
            # step evaluates them ON THE HOST. A first-time eval is the user's
            # own fresh DIRENV_ALLOW=1; a *changed* input is exactly the
            # guest-to-host path the README warns about, so it needs a human
            # (or an explicit DIRENV_REEVAL=1) to proceed.
            if [ -n "$_CACHED_HASH" ] && [ "$_CURRENT_HASH" != "$_CACHED_HASH" ] \
               && [ -z "''${DIRENV_REEVAL:-}" ]; then
              echo "note: the project's Nix files (flake.nix/devenv.*) changed since the dev"
              echo "      shell was last cached — by your own host edits, or by a previous VM"
              echo "      session writing /work. Re-evaluating runs their Nix code on the HOST,"
              echo "      so it is gated when the source is not already trusted."
              echo "      (DIRENV_REEVAL=1 skips this prompt; DIRENV_ALLOW=0 skips the dev shell.)"
              _DIRENV_ANSWER=""
              if [ -t 0 ]; then
                read -r -p "re-evaluate on the host? [y/N] " _DIRENV_ANSWER
              fi
              case "$_DIRENV_ANSWER" in
                y|Y|yes) ;;
                *)
                  echo "not evaluating. The previous dev shell cache (if any) is used as-is;"
                  echo "review the changes and relaunch, or set DIRENV_REEVAL=1 to re-evaluate"
                  echo "without this prompt."
                  _DEVSHELL_SKIP_EVAL=1
                  ;;
              esac
            fi
            if [ -z "''${_DEVSHELL_SKIP_EVAL:-}" ] \
               && { [ "$_CURRENT_HASH" != "$_CACHED_HASH" ] || [ ! -s "$_DEVSHELL_CACHE" ]; }; then
              echo "caching dev shell environment..."
              case "$_CACHE_CMD" in
                devenv\ *)
                  if ! command -v devenv >/dev/null 2>&1; then
                    echo "warning: $WORK is a devenv project, but devenv is not on PATH — the dev shell will not be available in the VM"
                  fi
                  ;;
              esac
              if (cd "$WORK" && eval "$_CACHE_CMD") > "$_DEVSHELL_CACHE.tmp" 2>"$_DEVSHELL_CACHE.err"; then
                mv "$_DEVSHELL_CACHE.tmp" "$_DEVSHELL_CACHE"
                echo "$_CURRENT_HASH" > "$_DEVSHELL_CACHE.hash"
                rm -f "$_DEVSHELL_CACHE.err"
              else
                rm -f "$_DEVSHELL_CACHE.tmp"
                echo "warning: could not cache the dev shell; see ~/.microvm-devshell.err in the VM"
              fi
            fi
          fi
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
            ".backup '$INSTANCE_GUEST/nix-db.sqlite'" \
            "COMMIT;" \
            > /dev/null \
            || rm -f "$INSTANCE_GUEST/nix-db.sqlite"
        fi

        # --- Guest share (virtiofsd, read-only) ---
        # Exports guest/ only, never the instance dir around it. Started last,
        # once everything above has written its file: from here on guest/ is
        # only read, so it is made read-only and owner-only now — files 0400,
        # dirs 0500 — against accidental edits or removal on the host, and
        # sticky (see the instance dir's creation). --readonly is the guarantee
        # against the guest — virtiofsd refuses every write, so root in the
        # guest cannot change these files whatever it remounts; the modes do
        # not add to it. --translate-uid shows them as the agent's, so the
        # 0400 env file stays readable by the agent and by no one else.
        chmod -R a-w,go-rwx,+t "$INSTANCE_GUEST"
        ${pkgs.systemd}/bin/systemd-run --user --unit="$GUEST_UNIT" --collect "''${_UNIT_PROPS[@]}" "$(describe "virtiofsd for the read-only guest share")" \
          -- ${virtiofsd}/bin/virtiofsd \
            --socket-path="$GUEST_SOCK" \
            --shared-dir="$INSTANCE_GUEST" \
            --readonly \
            --sandbox=namespace \
            --uid-map ":0:$(id -u):1:" \
            --gid-map ":0:$(id -g):1:" \
            --translate-uid "map:1000:0:1" \
            --translate-gid "map:1000:0:1" \
            --socket-group="$(id -gn)"

        for i in $(seq 1 50); do
          [ -S "$GUEST_SOCK" ] && break
          sleep 0.1
        done
        [ -S "$GUEST_SOCK" ] || { echo "error: guest-share virtiofsd socket did not appear"; exit 1; }

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
          -e "s|/tmp/${hostname}-instance|$INSTANCE_GUEST|g"
          -e "s|${hostname}-virtiofs-instance.sock|$GUEST_SOCK|g"
          # QEMU's QMP socket: microvm.socket is a relative "<hostname>.sock",
          # which would land in whatever directory the launcher runs from, and
          # two launches from one directory would take it from each other.
          -e "s|-qmp unix:${hostname}.sock,|-qmp unix:$QMP_SOCK,|g"
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

        case "$EGRESS_POLICY" in
          monitor|alert)
            _SED_ARGS+=(
              # Attach a capture object to the netdev. filter-dump sees every
              # frame the guest sends or receives; maxlen truncates each packet
              # so the capture records headers, DNS and TLS ClientHello (SNI)
              # without retaining whole payloads. 4096 because a post-quantum
              # hybrid-kex ClientHello runs ~1.8 KiB and SNI extraction needs it
              # complete — while TSO super-frames (up to 64 KiB of bulk data per
              # frame on virtio-net) still truncate to 4 KiB, which is where the
              # capture-size saving actually comes from. The anchor was verified
              # above.
              -e "s|-netdev 'user,id=usernet'|-netdev 'user,id=usernet' -object 'filter-dump,id=egress-dump,netdev=usernet,file=$_EGRESS_PCAP_ESC,maxlen=''${EGRESS_PCAP_MAXLEN:-4096}'|"
            )
            if [ "$EGRESS_POLICY" = "alert" ]; then
              EGRESS_UNIT="$_EGRESS_UNIT_NAME"
              ${pkgs.systemd}/bin/systemd-run --user --unit="$EGRESS_UNIT" --collect "''${_UNIT_PROPS[@]}" "$(describe "egress alert follower")" \
                -- ${egressReport}/bin/egress-report follow "$EGRESS_PCAP" \
                   --allowlist "$_EGRESS_ALLOWLIST_FILE" --alerts "$EGRESS_ALERTS"
            fi
            ;;
          shadow|enforce)
            _SED_ARGS+=(
              # Seal the netdev: restrict=on drops every flow except the one
              # guestfwd hole, which hands each guest connection to a socat
              # bridging into the host-side proxy ("cmd:" spawns one per
              # connection — a chardev target would multiplex them all over a
              # single stream and break concurrent requests). This also closes
              # the guest-to-host 10.0.2.2 path as a side effect.
              -e "s|-netdev 'user,id=usernet'|-netdev 'user,id=usernet,restrict=on,guestfwd=tcp:${egressGuestAddr}-cmd:${pkgs.socat}/bin/socat STDIO TCP:127.0.0.1:$_EGRESS_PORT'|"
            )
            ;;
        esac

        # --- Session contract (Phase 11): what this run can reach, printed
        # before boot so a surprise is visible while it is still cheap. Names
        # only for credentials — values never appear here.
        _CONTRACT_KEYS=""
        ${contractKeyChecks}
        # One row per concern: label, a status dot (green: contained, yellow:
        # worth knowing, red: the host is exposed), what it means, and a dim
        # hint at the knob that changes it.
        _dot() { case "$1" in ok) printf '%s● %s' "$_C_G" "$_C_0" ;; warn) printf '%s● %s' "$_C_Y" "$_C_0" ;; bad) printf '%s● %s' "$_C_R" "$_C_0" ;; *) printf '  ' ;; esac; }
        _row() { printf '  %s%-11s%s %s%s\n' "$_C_B" "$1" "$_C_0" "$(_dot "$2")" "$3"; }
        _cont() { printf '                %s\n' "$1"; }
        _hint() { printf '                %s%s%s\n' "$_C_D" "$1" "$_C_0"; }
        echo
        echo "$_C_B── session contract$_C_0 $_C_D· ${agentName}$_C_0 ${lib.concatStrings (lib.genList (_: "─") (57 - lib.stringLength agentName))}"
        if [ "$WORKSPACE_MODE" = "ephemeral" ]; then
          _row project ok "$(_tilde "$WORK") → /work, EPHEMERAL"
          _cont "writes stay in the VM and vanish at poweroff"
          _hint "vm-work-diff lists them; copy keepers to /home/agent"
        else
          _row project warn "$(_tilde "$WORK") → /work, read-write"
          _cont "edits appear on the host instantly"
          _hint "WORKSPACE_MODE=ephemeral keeps them in the VM"
        fi
        if [ "$WORK_CACHE" != "auto" ]; then
          _cont "virtiofs cache: $WORK_CACHE"
        fi
        _row "agent home" "" "$(_tilde "$AGENT_DIR") → /home/agent"
        _cont "persists across sessions"
        # The third share, and the one API keys arrive by: what this launch
        # hands the guest (see "Instance dir"). Listed as it actually is.
        _GUEST_HOLDS="env"
        if [ -d "$INSTANCE_GUEST/ca-certs" ]; then _GUEST_HOLDS="$_GUEST_HOLDS, CA certs"; fi
        if [ -f "$INSTANCE_GUEST/nix-db.sqlite" ]; then _GUEST_HOLDS="$_GUEST_HOLDS, nix DB snapshot"; fi
        _row "guest share" ok "this launch only → /run/microvm, read-only to the guest"
        _cont "$_GUEST_HOLDS; removed when the launch ends"
        if [ "''${DIRENV_ALLOW:-0}" = "1" ]; then
          _row "dev shell" bad "loaded from the project — its Nix code is evaluated on the HOST"
        else
          _row "dev shell" ok "not loaded"
          _hint "DIRENV_ALLOW=1 loads the project's dev shell (evaluated on the host)"
        fi
        if [ "''${WORKSPACE_GUARD:-}" = "1" ]; then
          _row workspace ok "guard on — host-executed config is read-only in the guest"
          _hint ".git/hooks, .git/config, .mcp.json, .claude/{commands,agents}, .envrc"
        else
          _row workspace warn "guard off — the guest may write host-executed config"
          _hint "WORKSPACE_GUARD=1 makes .git/hooks, .mcp.json, .envrc, … read-only"
        fi
        case "$EGRESS_POLICY" in
          open)
            _row egress bad "open — unrestricted, nothing recorded"
            _hint "EGRESS_POLICY=monitor to observe, shadow/enforce to seal" ;;
          monitor)
            _row egress warn "monitor — every flow recorded, nothing blocked"
            _hint "summary at session end; reports in $(_tilde "$EGRESS_DIR")" ;;
          alert)
            _row egress warn "alert — every flow recorded, off-list ones flagged live"
            _hint "$(_tailf "$EGRESS_DIR/latest.alerts.log")" ;;
          shadow)
            _row egress warn "shadow — sealed; the proxy is the only way out but blocks nothing"
            _cont "would_deny lines show what enforce would block"
            _hint "$(_tailf "$EGRESS_DIR/latest.audit.jsonl")" ;;
          enforce)
            _row egress ok "enforce — sealed; the proxy is the only way out, allowlist enforced"
            _cont "tools see only '403 from proxy' for a denied host"
            _hint "$(_tailf "$EGRESS_DIR/latest.audit.jsonl")" ;;
        esac
        if [ -n "$_EGRESS_RULES" ] && [ -f "$_EGRESS_RULES" ]; then
          cat "$_EGRESS_RULES"
        fi
        case "$EGRESS_POLICY" in
          shadow|enforce)
            if [ -n "$_CONTRACT_KEYS" ]; then
              _row "credentials" ok "''${_CONTRACT_KEYS# } — placeholders in the guest, real keys stay with the proxy"
            else
              _row "credentials" "" "no API keys (OAuth passes through the proxy)"
            fi ;;
          *)
            if [ -n "$_CONTRACT_KEYS" ]; then
              _row "credentials" warn "''${_CONTRACT_KEYS# } — real keys inside the guest"
              _hint "EGRESS_POLICY=shadow|enforce keeps them with the host-side proxy"
            else
              _row "credentials" "" "no API keys"
            fi ;;
        esac
        if [ -n "$_CONTRACT_EXTRA" ]; then
          _row "extra env" warn "''${_CONTRACT_EXTRA# } (EXTRA_ENV, values not shown)"
        fi
        if [ "$CRI_ATTACH" -eq 1 ]; then
          if [ -n "''${ENABLE_CRI:-}" ]; then
            _row containers "" "$ENABLE_CRI — storage disk attached, ''${CRI_STORAGE_SIZE} MiB cap at creation"
          else
            _row containers "" "runtimes off; the existing storage disk stays attached"
          fi
        else
          _row containers "" "off"
        fi
        _row resources "" "''${VM_MEM} MiB RAM · $VM_VCPU vCPUs${lib.optionalString storeDiskBacked " · writable store \${VM_STORE_SIZE} MiB, fresh each boot"}"
        # The handle on this launch from outside the VM: its units, its slice,
        # its journal tag and its instance dir all carry the ID.
        _row launch "" "$ID · $INSTANCE_DIR/"
        # microvm-stop presses the VM's power button over QMP, so the guest
        # shuts down cleanly and this launcher cleans up — with or without a
        # scope. Stopping the slice is no substitute: it kills QEMU outright,
        # and without a scope it would stop only the daemons, leaving the VM
        # running on shares that have gone. Named as this launcher was run,
        # since it ships beside it (./result/bin/microvm-stop after `make`).
        case "$0" in
          */*) _STOP_CMD="$(dirname -- "$0")/microvm-stop" ;;
          *) _STOP_CMD=microvm-stop ;;
        esac
        [ -x "$_STOP_CMD" ] || _STOP_CMD=microvm-stop
        _hint "stop: $_STOP_CMD $ID"
        echo "$_C_D────────────────────────────────────────────────────────────────────────────────$_C_0"
        # The contract is the last thing before the kernel's boot log scrolls
        # it away, so pause on it — but only with a terminal to read it and a
        # human to press the key. A pipe or NO_PAUSE=1 skips straight to boot;
        # a one-shot run (AGENTS_ARGS with -p) started at a terminal still waits.
        if [ -t 0 ] && [ "''${NO_PAUSE:-0}" != "1" ]; then
          read -r -p "press Enter to boot (NO_PAUSE=1 to skip this) … " _ || true
        fi

        # Run QEMU with corrected paths
        _VM_RC=0
        bash <(${pkgs.gnused}/bin/sed "''${_SED_ARGS[@]}" ${runner}/bin/microvm-run) || _VM_RC=$?

        case "$EGRESS_POLICY" in
          monitor|alert)
            if [ -n "$EGRESS_UNIT" ]; then
              ${pkgs.systemd}/bin/systemctl --user stop "$EGRESS_UNIT" 2>/dev/null || true
              EGRESS_UNIT=""
            fi
            _EGRESS_REPORT="$EGRESS_DIR/session-$_EGRESS_STAMP.report.txt"
            _EGRESS_RC=0
            ${egressReport}/bin/egress-report summarize "$EGRESS_PCAP" \
              ''${_EGRESS_ALLOWLIST_FILE:+--allowlist} ''${_EGRESS_ALLOWLIST_FILE:+"$_EGRESS_ALLOWLIST_FILE"} \
              > "$_EGRESS_REPORT" 2>&1 || _EGRESS_RC=$?
            ln -sfn "$(basename "$_EGRESS_REPORT")" "$EGRESS_DIR/latest.report.txt"
            echo
            cat "$_EGRESS_REPORT"
            echo "egress report saved: $_EGRESS_REPORT"
            if [ "$_EGRESS_RC" -eq 2 ]; then
              echo "egress alert: destinations outside the allowlist — see the violations section above"
            elif [ "$_EGRESS_RC" -ne 0 ]; then
              echo "warning: egress report failed (exit $_EGRESS_RC) — see $_EGRESS_REPORT" >&2
            fi
            if [ -n "''${EGRESS_KEEP_PCAP:-}" ]; then
              echo "egress capture kept: $EGRESS_PCAP"
            fi
            # cleanup() removes the capture (unless EGRESS_KEEP_PCAP is set):
            # the summary is the artifact that persists, not the raw traffic.
            ;;
          shadow|enforce)
            if [ -n "$EGRESS_UNIT" ]; then
              ${pkgs.systemd}/bin/systemctl --user stop "$EGRESS_UNIT" 2>/dev/null || true
              EGRESS_UNIT=""
            fi
            _allow=$(grep -c '"decision":"allow"' "$EGRESS_AUDIT" 2>/dev/null) || _allow=0
            _deny=$(grep -c '"decision":"deny"' "$EGRESS_AUDIT" 2>/dev/null) || _deny=0
            _would=$(grep -c '"decision":"would_deny"' "$EGRESS_AUDIT" 2>/dev/null) || _would=0
            echo
            echo "egress ($EGRESS_POLICY): $_allow allowed, $_deny denied, $_would would-deny"
            if [ "$_would" -gt 0 ]; then
              echo "  shadow found traffic enforce would block — the hosts are in the audit log:"
              echo "  grep would_deny '$EGRESS_AUDIT'"
            fi
            if [ "$_deny" -gt 0 ]; then
              echo "  denied hosts and the way to allow them: grep '\"decision\":\"deny\"' '$EGRESS_AUDIT'"
            fi
            echo "egress audit log saved: $EGRESS_AUDIT"
            ;;
        esac
        exit "$_VM_RC"
      '';
        # microvm-stop beside microvm-run, so a launch can name it in its
        # contract and result/bin/ has both.
        in pkgs.symlinkJoin {
          name = "microvm-run";
          paths = [ launcher (mkMicrovmStop pkgs) ];
          meta.mainProgram = "microvm-run";
        };
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
              microvm-policy.nixosModules.default
              # Its other defaults match this repo's layout; its state file is
              # the launcher's env file, on the read-only instance share.
              ({ config, ... }: {
                microvmPolicy.stateFile = "${config.claude-vm.instance.dir}/env";
                microvmPolicy.stateAfter = [ config.claude-vm.instance.mountUnit ];
              })
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

      packages = forSystems (system: let
        pkgs = nixpkgs.legacyPackages.${system};
        policyPkgs = microvm-policy.packages.${system};
      in
        { default = self.packages.${system}.claude;
          # Re-exported from microvm-policy so `nix run .#egress-report`
          # keeps working against this flake.
          inherit (policyPkgs) egress-report egress-proxy;
          # Also in every flavor's package, beside microvm-run; on its own for
          # whatever drives launches from outside (`nix run .#microvm-stop`).
          microvm-stop = mkMicrovmStop pkgs;
        } //
        builtins.mapAttrs (name: flavor: let
          nixosCfg = self.nixosConfigurations."${name}${flavor.suffix}-${system}".config;
          runner = nixosCfg.microvm.runner.qemu;
        in mkRunnerScript {
          inherit pkgs runner;
          egressReport = policyPkgs.egress-report;
          egressProxy = policyPkgs.egress-proxy;
          flavorEndpoints = egressEndpoints.${name};
          inherit (flavor) dataDirName apiKeyVars settingsFile;
          agentName = name;
          defaultMem = nixosCfg.claude-vm.agent.mem;
          defaultVcpu = nixosCfg.claude-vm.agent.vcpu;
          defaultCriSize = nixosCfg.claude-vm.cri.storageSize;
          storeDiskBacked = nixosCfg.claude-vm.store.diskBacked;
          defaultStoreSize = nixosCfg.claude-vm.store.size;
          # The session allowlist is assembled from these at launch, each line
          # tagged with its label so the session contract can show its source.
          egressAllowlistSources =
            [ { label = "built-in · common.txt (microvm-policy)"; file = "${microvm-policy}/allowlists/common.txt"; } ]
            ++ map (f: { label = "built-in · ${baseNameOf f}"; file = f; }) flavor.egressAllowlists;
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
        env-file-data-only = import ./tests/env-file-data-only.nix {
          inherit pkgs lib;
          config = self.nixosConfigurations."claude-${system}".config;
        };
        microvm-stop = import ./tests/microvm-stop.nix {
          inherit pkgs lib;
          microvmStop = self.packages.${system}.microvm-stop;
        };
        launch-scope = import ./tests/launch-scope.nix {
          inherit pkgs lib;
          runner = self.packages.${system}.claude;
        };
        instance-share = import ./tests/instance-share.nix {
          inherit pkgs lib;
          runner = self.packages.${system}.claude;
          config = self.nixosConfigurations."claude-${system}".config;
        };
        seed-idempotence = import ./tests/seed-idempotence.nix {
          inherit pkgs lib;
          config = self.nixosConfigurations."claude-${system}".config;
        };
        devshell-detection = import ./tests/devshell-detection.nix {
          inherit pkgs lib;
          runner = self.packages.${system}.claude;
        };
        settings-seed = import ./tests/settings-seed.nix {
          inherit pkgs lib;
          runner = self.packages.${system}.claude;
        };
        work-cache = import ./tests/work-cache.nix {
          inherit pkgs lib;
          runner = self.packages.${system}.claude;
        };
        # The proxy's own tests (Go units, egress-report, egress-integration)
        # run in microvm-policy's CI. This one stays: it tests the launcher's
        # config generation against the proxy it actually ships with.
        egress-config = import ./tests/egress-config.nix {
          inherit pkgs lib;
          runner = self.packages.${system}.claude;
          egressProxy = self.packages.${system}.egress-proxy;
        };
      });
    };
}
