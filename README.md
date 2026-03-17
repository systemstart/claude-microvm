# claude-vm

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in an isolated NixOS microVM via [microvm.nix](https://github.com/microvm-nix/microvm.nix) (QEMU+KVM). Your project directory is mounted read-write at `/work` inside the guest via virtiofs — no root required.

Claude Code starts automatically on boot. Exiting claude shuts down the VM.

## Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- KVM support (`/dev/kvm`)

## Quick start

```sh
# Build and run with current directory mounted at /work
make vm.run

# Mount a specific project directory
WORK_DIR=/path/to/project make vm.run

# Run multiple VMs on the same project (each gets a random instance ID)
make vm.run   # terminal 1
make vm.run   # terminal 2

# Load WORK_DIR's flake.nix dev shell into Claude Code's PATH
DIRENV_ALLOW=1 make vm.run

# Use a custom directory for Claude Code home
CLAUDE_HOME=~/.claude-vm make vm.run
```

## Usage from anywhere

### `nix run` (no install)

```sh
# From the repo directory
WORK_DIR=. nix run

# From a local checkout
WORK_DIR=/path/to/project nix run /path/to/this/repo

# Directly from git
WORK_DIR=. nix run github:systemstart/claude-microvm
```

### Install to PATH

```sh
nix profile install github:systemstart/claude-microvm

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
        packages = [ claude-vm.packages.${system}.vm ];
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

If your project has a `flake.nix` with a dev shell, set `DIRENV_ALLOW=1` to make those tools available to Claude Code inside the VM:

```sh
DIRENV_ALLOW=1 WORK_DIR=/path/to/project make vm.run
```

The dev shell environment is evaluated on the **host** via `nix print-dev-env` (where nix caches make it fast) and cached in `CLAUDE_HOME`. The cache is invalidated automatically when `flake.nix` or `flake.lock` changes. The VM sources the cached result on boot — no nix evaluation inside the guest.

If the host-side cache is unavailable, the VM falls back to evaluating via direnv + nix-direnv inside the guest (slower).

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
| RAM      | 4096 MB |
| vCPUs    | 4       |
| Network  | User-mode (SLiRP) |
| Work dir | Host directory via virtiofs (read-write) |
| Home dir | `~/.local/share/claude-microvm/<hash>` (shared across instances) or custom via `CLAUDE_HOME` |

### Environment variables

| Variable | Description | Default |
|----------|-------------|---------|
| `WORK_DIR` | Host directory to mount at `/work` | Current directory |
| `CLAUDE_HOME` | Host directory for Claude Code state (mounted at `/home/claude`) | `$XDG_DATA_HOME/claude-microvm/<hash>` |
| `DIRENV_ALLOW` | Set to `1` to load the project's `flake.nix` dev shell into Claude Code's environment | `0` |
