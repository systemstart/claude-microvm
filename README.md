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

# Named instances for persistent Claude home directories
INSTANCE=alex make vm.run
INSTANCE=review make vm.run

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

Each work directory gets its own virtiofsd instance, so multiple VMs can run in parallel on different projects. Multiple VMs on the **same** project also work automatically — each launch gets a random instance ID with its own virtiofsd daemons and sockets. For named, persistent sessions use the `INSTANCE` variable:

```sh
INSTANCE=alex make vm.run     # persistent session "alex"
INSTANCE=review make vm.run   # persistent session "review"
```

The virtiofsd daemons are cleaned up automatically when the VM exits.

### Home directory persistence

By default, `CLAUDE_HOME` is set to `$WORK_DIR/.claude-home` and shared across all instances on the same project, so sessions, credentials, auto-memory, and settings persist across VM restarts. To use a different directory, set `CLAUDE_HOME` explicitly:

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
| Home dir | `$WORK_DIR/.claude-home` (shared across instances) or custom via `CLAUDE_HOME` |
