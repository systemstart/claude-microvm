# claude-vm

Run AI coding agents in isolated NixOS microVMs via [microvm.nix](https://github.com/microvm-nix/microvm.nix) (QEMU+KVM). Your project directory is mounted read-write at `/work` inside the guest via virtiofs — no root required.

The agent starts automatically on boot. Exiting the agent shuts down the VM.

## Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- KVM support (`/dev/kvm`)

## Flavors

Each flavor packages a different AI coding agent. The VM is built as composable NixOS modules under `modules/`:

| Flavor | Package | API key | Description |
|--------|---------|---------|-------------|
| `claude` (default) | `.#claude` | `ANTHROPIC_API_KEY` | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) |
| `gemini` | `.#gemini` | `GEMINI_API_KEY` | Google Gemini CLI |
| `codex` | `.#codex` | `OPENAI_API_KEY` | OpenAI Codex CLI |
| `pi` | `.#pi` | `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY` | [Pi Coding Agent](https://github.com/earendil-works/pi) |

All flavors include container runtime support (Docker, containerd, CRI-O, Podman) — activated at runtime via `ENABLE_CRI`.

> **Gemini CLI first login:** Choosing "Login with Google" restarts the CLI process, which causes the VM to shut down (the VM powers off when the agent exits). On the next launch the CLI prompts for a token with a login URL directly and works normally. This is a first-start-only issue.

## Quick start

```sh
# Build and run Claude Code (default) with current directory mounted at /work
make claude.run

# Build and run other agents
make gemini.run
make codex.run
make pi.run

# Mount a specific project directory
WORK_DIR=/path/to/project make claude.run

# Run multiple VMs on the same project (each gets a random instance ID)
make claude.run   # terminal 1
make claude.run   # terminal 2

# Load WORK_DIR's dev shell (flake.nix or devenv) into the agent's PATH
DIRENV_ALLOW=1 make claude.run

# Use a custom directory for agent home
AGENT_HOME=~/.claude-vm make claude.run
```

## Usage from anywhere

### `nix run` (no install)

```sh
# From the repo directory (Claude Code, default)
WORK_DIR=. nix run

# Other agents
WORK_DIR=. nix run .#gemini
WORK_DIR=. nix run .#codex
WORK_DIR=. nix run .#pi

# From a local checkout
WORK_DIR=/path/to/project nix run /path/to/this/repo
WORK_DIR=/path/to/project nix run /path/to/this/repo#gemini
WORK_DIR=/path/to/project nix run /path/to/this/repo#pi

# Directly from git
WORK_DIR=. nix run github:systemstart/claude-microvm
WORK_DIR=. nix run github:systemstart/claude-microvm#gemini
WORK_DIR=. nix run github:systemstart/claude-microvm#pi
```

### Install to PATH

```sh
# Claude Code (default)
nix profile install github:systemstart/claude-microvm

# Other agents
nix profile install github:systemstart/claude-microvm#gemini
nix profile install github:systemstart/claude-microvm#codex
nix profile install github:systemstart/claude-microvm#pi

# Now available everywhere
WORK_DIR=/path/to/project microvm-run
```

### As a flake input

Add as a dependency in another project's `flake.nix`:

```nix
{
  inputs.claude-vm.url = "github:systemstart/claude-microvm";

  outputs = { nixpkgs, claude-vm, ... }:
    let system = "x86_64-linux"; in {
      devShells.${system}.default = nixpkgs.legacyPackages.${system}.mkShell {
        packages = [
          claude-vm.packages.${system}.claude   # Claude Code
          # claude-vm.packages.${system}.gemini # Gemini CLI
          # claude-vm.packages.${system}.codex  # Codex CLI
          # claude-vm.packages.${system}.pi     # Pi Coding Agent
        ];
      };
    };
}
```

Then `nix develop` gives you `microvm-run` in the shell.

## How it works

### virtiofs (host directory sharing)

The host `WORK_DIR` is shared into the VM at `/work` using virtiofs. A `virtiofsd` daemon is started automatically as a systemd user service (`<basename>-<agent>-vm-virtiofsd-<id>`, where `<basename>` is the project directory name and `<id>` is a random instance UUID) — no root or sudo needed. It runs unprivileged in a user namespace with UID/GID translation so files created inside the VM are owned by your host user.

Each work directory gets its own virtiofsd instance, so multiple VMs can run in parallel on different projects. Multiple VMs on the **same** project also work automatically — each launch gets a random instance ID with its own virtiofsd daemons and sockets.

The virtiofsd daemons are cleaned up automatically when the VM exits.

### Home directory persistence

Agent state (sessions, credentials, settings) is stored in `$XDG_DATA_HOME/<agent>-microvm/<basename>-<hash>` (defaulting to `~/.local/share/<agent>-microvm/<basename>-<hash>`), where `<agent>` is the flavor name, `<basename>` is the first 12 chars of the project directory name, and `<hash>` is derived from the `WORK_DIR` path. Each agent has its own isolated home directory. All instances of the same agent on the same project share this directory automatically. To use a different directory, set `AGENT_HOME` explicitly:

```sh
AGENT_HOME=~/.my-agent-home make claude.run
```

This mounts the host directory at `/home/agent` inside the guest via a second virtiofs share with the same unprivileged UID/GID mapping.

### Sandboxing

The VM provides strong isolation from the host:

- **Filesystem** — only `/work` and the home directory are shared read-write; everything else is VM-local and ephemeral
- **Nix store** — the host's `/nix/store` is shared as the lowerdir of the guest's store overlay, exported `readonly=on` so the guest cannot write through it
- **Processes** — completely isolated (separate kernel)
- **Network** — QEMU user-mode NAT; the VM can reach the internet but can't bind host ports

#### Hardening notes

Three things worth knowing before pointing this at code you don't trust:

- **`DIRENV_ALLOW=1` evaluates the work directory's Nix code on the host.** The dev
  shell cache runs `nix print-dev-env` (or `devenv print-dev-env`) against
  `$WORK_DIR` *outside* the VM, before boot. Since the guest can write `/work`,
  a `flake.nix` or `devenv.nix` modified during a session is evaluated on the
  host on the next launch — a guest-to-host path that needs no kernel bug. Don't
  combine `DIRENV_ALLOW=1` with a `WORK_DIR` whose contents you wouldn't run on
  the host yourself.
- **Unprivileged user namespaces are enabled in the guest** (the NixOS default).
  That gives an unprivileged guest user namespaced `CAP_NET_ADMIN` and reach into
  subsystems such as `net/sched`, the entry point for a recurring class of local
  privilege escalations — i.e. guest root is not far out of reach. The VM boundary
  is the security boundary here, not the guest's own user separation. Disabling
  them (`security.allowUserNamespaces = false`) would close it but breaks the Nix
  sandbox inside the guest, and `security.lockKernelModules` conflicts with
  `ENABLE_CRI`, so neither is on by default.
- **On a single-user Nix install, the read-only store share is the only thing
  protecting the host store.** The `ro-store` share is exported `readOnly`, and on
  NixOS or a multi-user install the host store is additionally not writable by the
  user QEMU runs as — a guest write fails on both counts. A single-user install
  (`/nix` owned by the user who installed Nix) has only the first: QEMU runs as the
  owner of every store path, who can change their modes at will. Don't remove
  `readOnly` from that share, and treat store integrity as unprotected if you run
  the VM as the store's owner with the flag off.

### Shutting down

Exiting the agent automatically powers off the VM.

### Nix dev shell support

If your project has a `flake.nix` dev shell or uses [devenv](https://devenv.sh/), set `DIRENV_ALLOW=1` to make those tools available inside the VM:

```sh
DIRENV_ALLOW=1 WORK_DIR=/path/to/project make claude.run
```

The dev shell environment is cached on the host and sourced on VM boot — no nix evaluation inside the guest:

- **Flake projects** (`flake.nix`): cached via `nix print-dev-env`
- **Flake-based devenv** (`flake.nix` + `devenv.nix`): cached via `nix print-dev-env --impure`
- **Non-flake devenv** (`.devenv.flake.nix`): cached via `devenv print-dev-env` (requires `devenv` on host PATH)

The cache is invalidated automatically when `flake.nix`, `flake.lock`, `.devenv.flake.nix`, `devenv.nix`, `devenv.yaml`, or `devenv.lock` changes. If caching fails, check `~/.microvm-devshell.err` inside the VM for the error.

### Custom CA certificates

If your network uses a private CA (e.g., corporate TLS inspection proxy), set `EXTRA_CA_CERTS` to inject the CA certificate into the VM's trust store:

```sh
# Single PEM file
EXTRA_CA_CERTS=/path/to/corporate-ca.pem make claude.run

# Directory of PEM files
EXTRA_CA_CERTS=/path/to/certs/ make claude.run
```

The custom certificates are appended to the system CA bundle at boot, before the agent starts. All tools (curl, git, Nix, etc.) will trust servers signed by the custom CA.

### Extra environment variables

`EXTRA_ENV` forwards arbitrary environment variables into the guest, where they
are exported into the agent's environment. Entries are comma-separated:

```sh
# Literal assignment
EXTRA_ENV="LANG=de_DE.UTF-8,TZ=Europe/Berlin" make claude.run

# A bare name forwards that variable's value from the host environment
export HTTPS_PROXY=http://proxy.internal:3128
EXTRA_ENV="HTTPS_PROXY" make claude.run

# Mix both
EXTRA_ENV="HTTPS_PROXY,LOG_LEVEL=debug" make claude.run
```

Prefer the bare-name form for secrets: the value never appears on the command
line, where `ps` would expose it to other users on the host, nor in shell
history.

Values may contain `=` (only the first one splits), but **not** commas — those
always separate entries. Whitespace around an entry is trimmed. Invalid variable
names and bare names that aren't set on the host are skipped with a warning.

Because agent config files live in the agent home directory (host-provided) and
can interpolate environment variables, this is also the way to point an agent at
a private or self-hosted endpoint — the token stays on the host and nothing
endpoint-specific is baked into the image.

> Values are written to `.microvm-env` (mode `600`) in the agent home directory
> and are readable by anything running in the guest, including the agent itself.

## Customization

### Exposing ports

No ports are forwarded by default. To expose ports, edit `modules/base.nix`:

```nix
microvm.qemu.extraArgs = [
  "-netdev" "user,id=usernet,hostfwd=tcp::8080-:8080"
  "-device" "virtio-net-device,netdev=usernet"
];
networking.firewall.allowedTCPPorts = [ 8080 ];
```

Rebuild with `make claude`.

### VM specs

| Resource | Default |
|----------|---------|
| RAM      | 8192 MB (CRI module overrides base 4096 MB) |
| vCPUs    | 4       |
| Network  | User-mode (SLiRP) |
| Work dir | Host directory via virtiofs (read-write) |
| Home dir | `~/.local/share/<agent>-microvm/<basename>-<hash>` (shared across instances) or custom via `AGENT_HOME` |

### Environment variables

| Variable | Description | Default |
|----------|-------------|---------|
| `WORK_DIR` | Host directory to mount at `/work` | Current directory |
| `AGENT_HOME` | Host directory for agent state (mounted at `/home/agent`) | `$XDG_DATA_HOME/<agent>-microvm/<hash>` |
| `VM_MEM` | VM memory in MB | `8192` |
| `VM_VCPU` | VM vCPU count | `4` |
| `DIRENV_ALLOW` | Set to `1` to load the project's dev shell (flake.nix or devenv) into the agent's environment | `0` |
| `ENABLE_CRI` | Comma-separated list of container runtimes to activate: `containerd`, `crun`, `crio`, `docker`, `podman` | (disabled) |
| `ANTHROPIC_API_KEY` | API key for Claude Code (claude flavor) | — |
| `GEMINI_API_KEY` | API key for Gemini CLI (gemini flavor) | — |
| `OPENAI_API_KEY` | API key for Codex CLI (codex flavor) and Pi (pi flavor) | — |
| `EXTRA_CA_CERTS` | Path to a PEM file or directory of PEM files containing custom CA certificates to trust inside the VM | (system CAs only) |
| `EXTRA_ENV` | Extra environment variables to forward into the VM, comma-separated. `FOO=bar` assigns a literal value; a bare `FOO` forwards `$FOO` from the host environment (keeps secrets off the command line). | (none) |
| `AGENTS_ARGS` | Extra arguments appended to the agent launch command. Use for one-shot prompts (e.g. `'-p "summarize this repo"'`) or to enable dangerous flags (e.g. `--dangerously-skip-permissions`). Re-parsed via `eval`, so quoting works. | (none) |

### Container runtime support

Container runtimes are included in every flavor and activated at runtime via `ENABLE_CRI`:

```sh
# Docker (includes Docker Compose)
ENABLE_CRI=docker make claude.run

# Single CRI runtime
ENABLE_CRI=containerd make claude.run

# Multiple runtimes
ENABLE_CRI=containerd,docker make claude.run

# crun (lightweight OCI runtime via a dedicated containerd instance)
ENABLE_CRI=crun make claude.run

# Podman
ENABLE_CRI=podman make claude.run
```

Container images and layers are stored on a dedicated ext4 disk image at `$AGENT_HOME-cri/cri-storage.img` (sparse, up to 30 GiB), mounted at `/var/lib/containers`, so they persist across VM restarts and don't consume the VM's RAM-backed root filesystem. The image is kept in a host-only sibling directory next to agent home rather than inside it, so it is never exported through the agent-home virtiofs share and the guest cannot read or tamper with its own raw storage backing file. A real block-backed filesystem is required here rather than a virtiofs share: image unpack must `lchown` extracted layers to UID 0, which the host's rootless virtiofsd cannot do (it has a single-ID uid map). On a share, `docker info` reports `Backing Filesystem: fuse` and overlay2/KinD layer extraction fails with `lchown … operation not permitted`; on the ext4 volume it reports `extfs` and works.

#### Available runtimes

| Value | Runtime | Socket |
|-------|---------|--------|
| `containerd` | containerd + runc | `/run/containerd/containerd.sock` |
| `crun` | containerd + crun | `/run/containerd-crun/containerd.sock` |
| `crio` | CRI-O (runc default, crun available) | `/run/crio/crio.sock` |
| `docker` | Docker daemon (includes Compose) | `/var/run/docker.sock` |
| `podman` | Podman API service | `/run/podman/podman.sock` |

#### CRI clients

All clients are pre-installed. Daemon sockets are group-readable by the VM user, so no `sudo` is needed:

```sh
# Docker
docker run --rm hello-world
docker compose up -d

# Podman (via podman.sock)
podman run --rm hello-world

# crictl — defaults to first activated CRI runtime's socket
crictl info
crictl images
crictl ps

# ctr — low-level containerd CLI (debugging/testing)
ctr images ls
ctr containers ls

# kubectl — for CRI inspection (no kubelet/cluster required)
kubectl get --raw /api 2>/dev/null || echo "no API server — use crictl for CRI access"
```

> **Note:** `nerdctl` is installed but does not work as a non-root user. It
> unconditionally enters a rootless-containerd code path when UID != 0 and
> fails before it ever reads the socket address. Use `docker`, `crictl`, or
> `ctr` instead.

#### CNI networking

A default bridge network (`cni0`, `10.88.0.0/16`) is configured automatically with masquerading, port mapping, and firewall support.
