# claude-vm

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in an isolated NixOS microVM via [microvm.nix](https://github.com/microvm-nix/microvm.nix) (QEMU+KVM). Your project directory is mounted read-write at `/work` inside the guest via virtiofs — no root required.

Claude Code starts automatically on boot. Exiting claude shuts down the VM.

## Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- KVM support (`/dev/kvm`)

## Flavors

The VM is built as composable NixOS modules under `modules/`:

| Flavor | Package | Description |
|--------|---------|-------------|
| `vm` (default) | `.#vm` | Lean base image — Claude Code, git, devenv |
| `vm-cri` | `.#vm-cri` | Base + container runtimes (Docker, containerd, CRI-O) |

## Quick start

```sh
# Build and run with current directory mounted at /work
make vm.run

# Build and run with container runtime support
make vm-cri.run

# Mount a specific project directory
WORK_DIR=/path/to/project make vm.run

# Run multiple VMs on the same project (each gets a random instance ID)
make vm.run   # terminal 1
make vm.run   # terminal 2

# Load WORK_DIR's dev shell (flake.nix or devenv) into Claude Code's PATH
DIRENV_ALLOW=1 make vm.run

# Use a custom directory for Claude Code home
CLAUDE_HOME=~/.claude-vm make vm.run
```

## Usage from anywhere

### `nix run` (no install)

```sh
# From the repo directory (base flavor)
WORK_DIR=. nix run

# With container runtime support
WORK_DIR=. nix run .#vm-cri

# From a local checkout
WORK_DIR=/path/to/project nix run /path/to/this/repo
WORK_DIR=/path/to/project nix run /path/to/this/repo#vm-cri

# Directly from git
WORK_DIR=. nix run github:systemstart/claude-microvm
WORK_DIR=. nix run github:systemstart/claude-microvm#vm-cri
```

### Install to PATH

```sh
# Base flavor
nix profile install github:systemstart/claude-microvm

# CRI flavor
nix profile install github:systemstart/claude-microvm#vm-cri

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
          claude-vm.packages.${system}.vm       # base
          # claude-vm.packages.${system}.vm-cri # with container runtimes
        ];
      };
    };
}
```

Then `nix develop` gives you `microvm-run` in the shell.

## How it works

### virtiofs (host directory sharing)

The host `WORK_DIR` is shared into the VM at `/work` using virtiofs. A `virtiofsd` daemon is started automatically as a systemd user service (`claude-vm-virtiofsd-<id>`, where `<id>` is derived from the work directory path) — no root or sudo needed. It runs unprivileged in a user namespace with UID/GID translation so files created inside the VM are owned by your host user.

Each work directory gets its own virtiofsd instance, so multiple VMs can run in parallel on different projects. Multiple VMs on the **same** project also work automatically — each launch gets a random instance ID with its own virtiofsd daemons and sockets.

The virtiofsd daemons are cleaned up automatically when the VM exits.

### Home directory persistence

Claude Code state (sessions, credentials, settings) is stored in `$XDG_DATA_HOME/claude-microvm/<hash>` (defaulting to `~/.local/share/claude-microvm/<hash>`), where `<hash>` is derived from the `WORK_DIR` path. All instances on the same project share this directory automatically. To use a different directory, set `CLAUDE_HOME` explicitly:

```sh
CLAUDE_HOME=~/.claude-vm make vm.run
```

This mounts the host directory at `/home/claude` inside the guest via a second virtiofs share with the same unprivileged UID/GID mapping. Claude Code stores state in both `~/.claude/` and `~/.claude.json`, so mounting the entire home directory ensures everything persists.

### Sandboxing

The VM provides strong isolation from the host:

- **Filesystem** — only `/work` and optionally the home directory are shared; everything else is VM-local and ephemeral
- **Processes** — completely isolated (separate kernel)
- **Network** — QEMU user-mode NAT; the VM can reach the internet but can't bind host ports

To let Claude Code run fully autonomously inside the VM (no permission prompts), add `--dangerously-skip-permissions` to the `claude` invocation in `flake.nix`.

### Shutting down

Exiting Claude Code automatically powers off the VM.

### Nix dev shell support

If your project has a `flake.nix` dev shell or uses [devenv](https://devenv.sh/), set `DIRENV_ALLOW=1` to make those tools available to Claude Code inside the VM:

```sh
DIRENV_ALLOW=1 WORK_DIR=/path/to/project make vm.run
```

The dev shell environment is cached on the host and sourced on VM boot — no nix evaluation inside the guest:

- **Flake projects** (`flake.nix`): cached via `nix print-dev-env`
- **Flake-based devenv** (`flake.nix` + `devenv.nix`): cached via `nix print-dev-env --impure`
- **Non-flake devenv** (`.devenv.flake.nix`): cached via `devenv print-dev-env` (requires `devenv` on host PATH)

The cache is invalidated automatically when `flake.nix`, `flake.lock`, `.devenv.flake.nix`, `devenv.nix`, `devenv.yaml`, or `devenv.lock` changes. If caching fails, check `~/.microvm-devshell.err` inside the VM for the error.

## Customization

### Exposing ports

No ports are forwarded by default. To expose ports, edit `flake.nix`:

```nix
microvm.qemu.extraArgs = [
  "-netdev" "user,id=usernet,hostfwd=tcp::8080-:8080"
  "-device" "virtio-net-device,netdev=usernet"
];
networking.firewall.allowedTCPPorts = [ 8080 ];
```

Rebuild with `make vm`.

### VM specs

| Resource | Default |
|----------|---------|
| RAM      | 4096 MB (base), 8192 MB (CRI) |
| vCPUs    | 4       |
| Network  | User-mode (SLiRP) |
| Work dir | Host directory via virtiofs (read-write) |
| Home dir | `~/.local/share/claude-microvm/<hash>` (shared across instances) or custom via `CLAUDE_HOME` |

### Environment variables

| Variable | Description | Default |
|----------|-------------|---------|
| `WORK_DIR` | Host directory to mount at `/work` | Current directory |
| `CLAUDE_HOME` | Host directory for Claude Code state (mounted at `/home/claude`) | `$XDG_DATA_HOME/claude-microvm/<hash>` |
| `DIRENV_ALLOW` | Set to `1` to load the project's dev shell (flake.nix or devenv) into Claude Code's environment | `0` |
| `ENABLE_CRI` | Comma-separated list of container runtimes to activate (vm-cri only): `containerd`, `crun`, `crio`, `docker` | (disabled) |

### Container runtime support

Container runtimes are available in the `vm-cri` flavor. Use `make vm-cri.run` or `nix run .#vm-cri` to build with CRI support, then activate runtimes via `ENABLE_CRI`:

```sh
# Docker (includes Docker Compose)
ENABLE_CRI=docker make vm-cri.run

# Single CRI runtime
ENABLE_CRI=containerd make vm-cri.run

# Multiple runtimes
ENABLE_CRI=containerd,docker make vm-cri.run

# crun (lightweight OCI runtime via a dedicated containerd instance)
ENABLE_CRI=crun make vm-cri.run
```

The `vm-cri` flavor defaults to 8 GiB RAM (vs 4 GiB for base). Container images and layers are stored on the host at `$CLAUDE_HOME/cri-storage/` via a dedicated virtiofs share at `/var/lib/containers`, so they persist across VM restarts and don't consume the VM's RAM-backed root filesystem.

#### Available runtimes

| Value | Runtime | Socket |
|-------|---------|--------|
| `containerd` | containerd + runc | `/run/containerd/containerd.sock` |
| `crun` | containerd + crun | `/run/containerd-crun/containerd.sock` |
| `crio` | CRI-O (runc default, crun available) | `/run/crio/crio.sock` |
| `docker` | Docker daemon (includes Compose) | `/var/run/docker.sock` |

#### CRI clients

All clients are pre-installed. Daemon sockets are group-readable by the `claude` user, so no `sudo` is needed:

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
