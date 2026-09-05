# claude-vm

Run AI coding agents in isolated NixOS microVMs via [microvm.nix](https://github.com/microvm-nix/microvm.nix) (QEMU+KVM). Your project directory is mounted read-write at `/work` inside the guest via virtiofs — no root required.

The agent starts automatically on boot. Exiting the agent shuts down the VM.

## Features

- **A VM boundary, not a container.** Separate kernel and process tree; the host is reachable only through what you explicitly share, and the network is user-mode NAT that cannot bind host ports.
- **Your project at `/work`, read-write.** Shared over virtiofs by an unprivileged daemon — no root or sudo, and files the guest creates are owned by your host user.
- **Start it and forget it.** The agent launches on boot; when it exits the VM powers off and its virtiofs daemons are cleaned up.
- **Per-project state that persists.** Sessions, credentials and settings live in a host directory that survives relaunches. Each agent gets its own; several VMs can run against the same project, or different ones in parallel.
- **Four agents from one set of modules.** Claude Code, Gemini CLI, Codex CLI and Pi — see [Flavors](#flavors).
- **Container runtimes on demand.** Docker, containerd, CRI-O and Podman, activated per launch with `ENABLE_CRI` and backed by a real disk rather than the share.
- **Your dev shell inside the guest.** A project's `flake.nix` or devenv shell is evaluated once on the host, cached, and sourced at boot — no Nix evaluation in the VM.
- **Little left behind.** The writable Nix store is a per-run sparse disk removed on exit; [Leaving nothing on the host](#leaving-nothing-on-the-host) inventories everything else and how to avoid it.

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

## Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- KVM support (`/dev/kvm`)

## Quick start

> [!IMPORTANT]
> **The first build compiles QEMU from source — roughly 20 minutes — unless you
> enable a binary cache first.** microvm.nix needs a QEMU variant that
> `cache.nixos.org` no longer carries, and the build recurs after every
> `flake.lock` bump that moves QEMU. Two caches serve it prebuilt as a ~35 MiB
> download, but enabling one is a trust decision, and on a multi-user Nix
> install answering the prompt is not enough on its own — see
> [Binary caches](#binary-caches).

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

## Binary caches

microvm.nix builds QEMU as `qemu_kvm.override { nixosTestRunner = true; }` (its
`microvm.optimize.enable` default, which keeps the QEMU closure at ~845 MiB
instead of ~1.5 GiB). Since nixpkgs dropped `hostCpuOnly` from `qemu_test`
([NixOS/nixpkgs#541354](https://github.com/NixOS/nixpkgs/pull/541354), merged
2026-07-21) that exact combination is no longer built by Hydra, so it is **not
in `cache.nixos.org`**. Building it from source takes roughly 20 minutes, and it
recurs after every `flake.lock` bump that moves QEMU or its dependencies — not
just on first use.

Two caches serve the prebuilt QEMU (~35 MiB download), and `flake.nix` declares
both in `nixConfig`:

| Cache | Who signs it | Populated by |
|-------|--------------|--------------|
| `systemstart.cachix.org` | this project | every CI build of `.#claude`/`.#gemini`/`.#codex`/`.#pi` |
| `microvm.cachix.org` | upstream [microvm.nix](https://github.com/microvm-nix/microvm.nix) | upstream CI (hits only when its nixpkgs pin matches ours) |

Substituters are a trust decision: a cache you enable can hand you any build
output it likes, signed with its own key. Pick whichever you prefer.

**Use the caches.** `nix build`/`nix run` (and `direnv reload`, via
`nix print-dev-env`) prompts once per setting, then offers to remember the
answer in `~/.local/share/nix/trusted-settings.json` — per user, keyed by the
exact value, not per repo:

```
do you want to allow configuration setting 'extra-substituters' to be set to
'https://systemstart.cachix.org https://microvm.cachix.org' (y/N)?
```

**Answering the prompts is not enough on a multi-user install.** `substituters`
and `trusted-public-keys` are *restricted settings*: the client hands them to
`nix-daemon`, which drops them unless you are listed in `trusted-users`. Both
gates are independent, so accepting the flake config and still getting no cache
looks like this:

```
do you want to permanently mark this value as trusted (y/N)? y
warning: ignoring untrusted substituter 'https://systemstart.cachix.org', you are not a trusted user.
warning: ignoring the client-specified setting 'trusted-public-keys', because it is a restricted setting and you are not a trusted user
```

The fix is daemon-side. Configure the caches system-wide — the narrower grant,
and it works no matter who runs the build:

```nix
# NixOS
nix.settings = {
  substituters = [ "https://systemstart.cachix.org" "https://microvm.cachix.org" ];
  trusted-public-keys = [
    "systemstart.cachix.org-1:hSTfDlXstyuVVukogR0sEmt8wJsaplp7NvisgUugNpE="
    "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys="
  ];
};
```

```conf
# non-NixOS: /etc/nix/nix.conf
extra-substituters = https://systemstart.cachix.org https://microvm.cachix.org
extra-trusted-public-keys = systemstart.cachix.org-1:hSTfDlXstyuVVukogR0sEmt8wJsaplp7NvisgUugNpE= microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys=
```

Restart the daemon afterwards (`systemctl restart nix-daemon`, or
`sudo launchctl kickstart -k system/org.nixos.nix-daemon` on macOS).

Adding yourself to `trusted-users` instead makes the flake's `nixConfig` work
directly, but that grant is effectively root-equivalent — a trusted user can
inject arbitrary paths into the store. Prefer the system-wide cache config above
unless you already trust yourself that far.

**Build it yourself.** Answer `N` at the prompt, or pass
`--no-accept-flake-config`, and Nix compiles QEMU from source. Everything else
still comes from `cache.nixos.org` — only QEMU is affected.

If you would rather never build QEMU *and* never add a third-party cache, set
`microvm.qemu.package = pkgs.qemu_test;` in `modules/base.nix`: that variant is
in `cache.nixos.org`, at the cost of ~575 MiB more closure (it carries every
target architecture, not just the host's).

## How it works

### virtiofs (host directory sharing)

The host `WORK_DIR` is shared into the VM at `/work` using virtiofs. A `virtiofsd` daemon is started automatically as a systemd user service (`<basename>-<agent>-vm-virtiofsd-<id>`, where `<basename>` is the project directory name and `<id>` is a random instance UUID) — no root or sudo needed. It runs unprivileged in a user namespace with UID/GID translation so files created inside the VM are owned by your host user.

Each work directory gets its own virtiofsd instance, so multiple VMs can run in parallel on different projects. Multiple VMs on the **same** project also work automatically — each launch gets a random instance ID with its own virtiofsd daemons and sockets.

The virtiofsd daemons are cleaned up automatically when the VM exits.

One failure mode is worth knowing before you meet it: virtiofsd holds a file
descriptor per inode the guest has looked up, so a large enough tree walk in the
VM can exhaust its descriptor limit, after which every operation on the share
fails with `Too many open files` while the guest's own counters look fine. It
does not clear on its own and retrying makes it worse. The guest ships
`vm-share-relieve` to recover in place —
[docs/VIRTIOFS-GOTCHAS.md](docs/VIRTIOFS-GOTCHAS.md) has the mechanism, the
prevention, and why the two flags usually suggested for this do not apply to a
rootless daemon.

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
  `ENABLE_CRI`, so neither is on by default. What the guest does do is refuse the
  on-demand autoload of the `net/sched` modules listed in
  `blockedTcModules` in `modules/base.nix`, which removes the most travelled
  route into `net/sched` without the `lockKernelModules` conflict. This is
  guest-internal defence in depth: `modprobe.d` constrains modprobe-mediated
  loads, not a direct `finit_module` from something already privileged in the
  guest. It narrows the path to guest root; it does not close it, and the VM
  remains the security boundary. If you add the CNI `bandwidth` plugin to the
  chain, drop `act_mirred` and `cls_u32` from the list.
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
- **devenv without a flake** (`devenv.nix`, as written by `devenv init`): cached via `devenv print-dev-env` (requires `devenv` on host PATH)

The cache is invalidated automatically when `flake.nix`, `flake.lock`, `.devenv.flake.nix`, `devenv.nix`, `devenv.yaml`, or `devenv.lock` changes. If caching fails, check `~/.microvm-devshell.err` inside the VM for the error. A launch that finds nothing to cache, or that needs `devenv` when it is not on PATH, says so on the console.

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
| Root fs  | RAM-backed tmpfs (50% of `VM_MEM`) |
| Nix store | Host store read-only over 9p, plus a 10 GiB sparse disk for what the VM writes — see [Writable Nix store disk](#writable-nix-store-disk) |

### Environment variables

| Variable | Description | Default |
|----------|-------------|---------|
| `WORK_DIR` | Host directory to mount at `/work` | Current directory |
| `AGENT_HOME` | Host directory for agent state (mounted at `/home/agent`) | `$XDG_DATA_HOME/<agent>-microvm/<hash>` |
| `AGENT_SETTINGS` | Host path to a settings file seeded into the agent home before boot (flavor-specific destination, e.g. `.claude/settings.json`) — see [Pre-seeding agent settings](#pre-seeding-agent-settings) | (none) |
| `VM_MEM` | VM memory in MB | `8192` |
| `VM_VCPU` | VM vCPU count | `4` |
| `DIRENV_ALLOW` | Set to `1` to load the project's dev shell (flake.nix or devenv) into the agent's environment | `0` |
| `ENABLE_CRI` | Comma-separated list of container runtimes to activate: `containerd`, `crun`, `crio`, `docker`, `podman` | (disabled) |
| `CRI_STORAGE_SIZE` | Cap on the CRI storage disk in MiB, applied when the image is first created. Sparse, so it is a ceiling rather than an allocation. `0` runs without the disk entirely. The disk is only *created* when `ENABLE_CRI` is set — see [Container runtime support](#container-runtime-support) | `30720` (30 GiB) |
| `VM_STORE_SIZE` | Cap on the writable Nix store disk in MiB. Sparse, and recreated on every launch, so it applies to every run. Minimum 1024; `0` is rejected — see [Leaving nothing on the host](#leaving-nothing-on-the-host) | `10240` (10 GiB) |
| `ANTHROPIC_API_KEY` | API key for Claude Code (claude flavor) | — |
| `GEMINI_API_KEY` | API key for Gemini CLI (gemini flavor) | — |
| `OPENAI_API_KEY` | API key for Codex CLI (codex flavor) and Pi (pi flavor) | — |
| `EXTRA_CA_CERTS` | Path to a PEM file or directory of PEM files containing custom CA certificates to trust inside the VM | (system CAs only) |
| `EXTRA_ENV` | Extra environment variables to forward into the VM, comma-separated. `FOO=bar` assigns a literal value; a bare `FOO` forwards `$FOO` from the host environment (keeps secrets off the command line). | (none) |
| `AGENTS_ARGS` | Extra arguments appended to the agent launch command. Use for one-shot prompts (e.g. `'-p "summarize this repo"'`) or to enable dangerous flags (e.g. `--dangerously-skip-permissions`). Re-parsed via `eval`, so quoting works. | (none) |

### Pre-seeding agent settings

A fresh workspace starts the agent with its default configuration. To start
from your own instead, point `AGENT_SETTINGS` at a settings file on the host:

```sh
AGENT_SETTINGS=~/dotfiles/claude-settings.json make claude.run
```

It lands at the flavor's own config path inside the agent home —
`.claude/settings.json` for Claude Code, `.gemini/settings.json` for Gemini,
`.codex/config.toml` for Codex (JSON destinations are validated before boot;
the `pi` flavor has no supported settings path and warns). This is a **seed,
not a sync**: the file is copied when missing and re-copied only when the host
file changes, so settings changed inside the VM persist across launches until
you edit the host copy — at which point the host version replaces the file
wholesale. A pre-existing file the seeding never wrote is backed up once as
`*.pre-seed` before being replaced.

It is also convenience, not enforcement — the guest can rewrite the file
mid-session like any other agent-home state.

### Writable Nix store disk

`/nix/store` in the guest is an overlay: the host's store, read-only over 9p,
with everything this VM writes on top. That writable half lives on its own
sparse ext4 image at `$AGENT_HOME-store/nix-store-overlay.img` (10 GiB by
default), mounted at `/nix/.rw-store` in the initrd before the overlay that uses
it. Nix build directories are pointed at the same disk, so a large unpack does
not land in RAM either.

The cap is a ceiling, not an allocation: a fresh image costs the host ~69 MiB of
ext4 metadata and grows only as the VM writes. It is also a containment
boundary — the guest should not be able to eat an unbounded slice of the host's
disk — which is why the default is modest rather than generous. Sizes up to
10 GiB all cost the same 69 MiB up front, so that is where the default sits.

It is a disk rather than the RAM-backed rootfs because of how much lands there.
Every `nix develop` on a **dirty git worktree** — the normal state while working
— cannot use the git object store as its source, so Nix snapshots the entire
working directory into the store as a `…-source` path, and mints a new one for
each distinct dirty state. Snapshots of a few hundred MiB are ordinary; a day of
render/commit cycles across a few repos can produce 15 GiB of them. On tmpfs
that is RAM, and the first thing to notice is a write failing:

```
error: write of 26300 bytes: No space left on device
```

The image is **recreated empty on every launch**, so each boot starts with a
clean writable store. That is deliberate: the guest imports a snapshot of the
host's Nix database at boot (see [docs/NIX-STORE-GOTCHAS.md](docs/NIX-STORE-GOTCHAS.md)),
which knows nothing about paths a previous run built, so a persistent image
would accumulate store paths Nix considers invalid and never reuses. Restarting
the VM therefore remains the guaranteed way back to an empty store — and it is
also why the image costs the host nothing while no VM is running.

Raise the ceiling for a heavy workload:

```sh
VM_STORE_SIZE=40960 make claude.run
```

To reclaim space without restarting, the guest ships `vm-store-prune`:

```sh
vm-store-prune              # delete the `…-source` worktree snapshots
vm-store-prune --all        # every VM-local path nothing references
vm-store-prune --dry-run    # list candidates, delete nothing
```

A timer runs the first of those for you when free space on the store disk drops
below 2 GiB (`claude-vm.store.autoPrune`). It is built not to become a load
source of its own: a tick that finds space is a single `statfs`, runs cannot
overlap or queue up behind each other (the interval is measured from when the
last run *finished*), and consecutive passes that free nothing — which is what
you get when a live dev shell is holding the space — back off 15m → 30m → 1h →
2h, resetting as soon as free space is healthy. The service is `Nice=19` with
idle I/O priority, so it yields to the agent's own work. Last outcome:

```sh
cat /run/vm-store-autoprune/status
```

Note this is *not* nix's `min-free`, which must stay 0 here: that hooks the
build loop and calls the full garbage collector, which on this overlay deletes
the host's store paths behind whiteouts. Same trigger, wrong collector.

Do **not** run `nix-collect-garbage` inside the guest. On this overlay it walks
every host path the imported database knows about and writes a whiteout into the
VM's writable layer for each one it wants to delete: it consumes the space it was
meant to free and hides host store paths from `/nix/store`. `vm-store-prune`
exists because the safe subset — paths present in the upper layer and absent
from the host's store — is not something to reconstruct by hand under disk
pressure.

Prevention is cheaper than cleanup: batch commits (every pre-commit hook that
shells out to `nix develop` can mint a snapshot), work inside one dev shell
rather than paying a flake evaluation per command, and keep `result*` symlinks
out of the tree — each one is a GC root that pins a snapshot.

Set `claude-vm.store.diskBacked = false` to go back to the RAM-backed store, or
`claude-vm.store.size` to change the default cap.

### Leaving nothing on the host

If you run the VM for the isolation and would rather it left no artifacts
behind, here is the complete inventory of what it writes outside the Nix store,
and what you can do about each:

| artifact | lifetime | how to avoid it |
|---|---|---|
| `$AGENT_HOME-cri/cri-storage.img` | persistent, ~133 MiB minimum, grows to the cap | not created unless `ENABLE_CRI` is set; `CRI_STORAGE_SIZE=0` also detaches an existing one |
| `$AGENT_HOME-store/nix-store-overlay.img` | per-run, ~69 MiB, deleted on exit along with its directory | build-time only: `claude-vm.store.diskBacked = false` |
| `$AGENT_HOME` (agent state, dev-shell cache, nix DB snapshot ~97 MiB) | persistent | point `AGENT_HOME` somewhere disposable |

The CRI disk used to be created on every launch whether or not `ENABLE_CRI` was
set, and it is never deleted. It is now only created for a run that asks for
container runtimes, so a workspace that never uses them accumulates nothing —
see [When the disk is created and attached](#when-the-disk-is-created-and-attached).
`CRI_STORAGE_SIZE=0` is the harder switch: it detaches even an existing image.
Either way the guest's mount carries `nofail`, so the VM boots without the
device and `/var/lib/containers` is just a directory. Pairing `CRI_STORAGE_SIZE=0`
with `ENABLE_CRI` is allowed but warns — container storage would land on the
VM's RAM.

```sh
CRI_STORAGE_SIZE=0 make claude.run
```

The writable store disk cannot be dropped the same way, and `VM_STORE_SIZE=0` is
rejected rather than silently doing something odd. That mount is `neededForBoot`
and `/nix/store`'s overlay hard-requires it, so a missing device is a failed boot
rather than a fallback — the one place where a tolerant mount would be a lie.
Its image is already per-run and removed on exit, so what it costs a host at rest
is nothing; if you want it gone during the run too, that is the build-time
`claude-vm.store.diskBacked = false`.

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

#### When the disk is created and attached

`ENABLE_CRI` decides which runtimes start inside the guest. It also decides
whether the disk gets *created* — but never whether an existing one is attached:

| `CRI_STORAGE_SIZE` | `ENABLE_CRI` | image on disk | result |
|---|---|---|---|
| unset | unset | none | no image, no directory, no drive |
| unset | set | none | created at the cap, attached |
| unset | either | exists | attached |
| `0` | any | any | never attached; an existing image is left untouched |

So a workspace launched once with `ENABLE_CRI=containerd,docker` and then
launched plain still has its disk attached: the layer cache, named volumes and
any KinD cluster are exactly where they were, and starting a runtime by hand
finds a real disk rather than silently writing to RAM. Only the runtimes stop
being started for you. Going the other way — plain first, then `ENABLE_CRI` —
creates the image on the first run that asks for it.

Nothing in the launcher ever deletes the image; detaching is reversible,
deleting is not. To reclaim the space, remove `$AGENT_HOME-cri/` yourself.

#### Sizing the CRI disk

The 30 GiB default is a cap on a sparse image: it costs host space only as it is
written. Raise it with `CRI_STORAGE_SIZE` (MiB) when you know the workload is
heavy:

```sh
# 60 GiB ceiling for a KinD cluster plus fixtures
CRI_STORAGE_SIZE=61440 ENABLE_CRI=docker,containerd make claude.run
```

Budget generously for Kubernetes-in-Docker. A single-node KinD cluster typically
occupies **15–25 GiB** of this disk, because every image `kind load`ed into the
node is stored a second time inside the node's own containerd — the copy in the
host Nix store does not help. One cluster can therefore fill most of the default
disk on its own, and it competes for that space with any host-side containerd or
Docker images, which share the same filesystem.

The size takes effect **when the image is created**. An existing
`$AGENT_HOME-cri/cri-storage.img` keeps the size it was made with, so to change
it either grow it in place while the VM is shut down:

```sh
truncate -s 61440M "$AGENT_HOME-cri/cri-storage.img"
e2fsck -f "$AGENT_HOME-cri/cri-storage.img"
resize2fs "$AGENT_HOME-cri/cri-storage.img"
```

or delete the image and let the next run recreate it. Deleting discards
everything on it — not just cached image layers but the state of any KinD
cluster or named volume living there — so prefer the in-place grow unless you
want a clean slate.

`CRI_STORAGE_SIZE=0` runs without the disk at all — see
[Leaving nothing on the host](#leaving-nothing-on-the-host). Container runtimes
then have nowhere real to put images, so it is meant for runs that do not use
them; pairing it with `ENABLE_CRI` warns and falls back to the VM's RAM.


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
