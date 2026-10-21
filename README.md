# claude-vm

Run AI coding agents in isolated NixOS microVMs via [microvm.nix](https://github.com/microvm-nix/microvm.nix) (QEMU+KVM). Your project directory is mounted read-write at `/work` inside the guest via virtiofs — no root required.

The agent starts automatically on boot. Exiting the agent shuts down the VM.

## Features

- **A VM boundary, not a container.** Separate kernel and process tree; the host is reachable only through what you explicitly share, and the network is user-mode NAT that cannot bind host ports.
- **Graduated egress policy.** `EGRESS_POLICY` goes from `open` through `monitor`/`alert` (host-side capture, observe only) to `shadow`/`enforce`: a sealed network whose only way out is an allowlisting proxy on the host, which also keeps API keys out of the guest. Every decision is audited, and shadow shows what enforce would block before it blocks anything — see [Egress policy](#egress-policy).
- **Workspace policies for untrusted code.** `WORKSPACE_MODE=ephemeral` keeps the agent's writes in a guest-side overlay that is discarded at poweroff (`vm-work-diff` shows what changed); `WORKSPACE_GUARD=1` makes host-executed config such as `.git/hooks` and `.mcp.json` read-only inside the guest — see [Ephemeral workspace](#ephemeral-workspace) and [Hardening notes](#hardening-notes).
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

> [!WARNING]
> **Since v0.16.0 every launch stops at the session contract and waits for
> Enter before booting.** It prints what the run can reach (workspace, egress
> rules, credentials) while stopping is still cheap. The pause applies only
> when stdin is a terminal, so pipes and cron jobs are unaffected, but
> automation that gives the launcher a terminal (tmux `send-keys`, `expect`,
> `script`, an IDE task runner, a systemd unit with `StandardInput=tty`) will
> hang waiting for input, and so does a one-shot `AGENTS_ARGS=-p …` run typed
> at a terminal. Set **`NO_PAUSE=1`** in those setups. The contract
> still prints; only the wait is skipped.

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
WORK_DIR=. nix run github:nix-gizmos/agent-vm
WORK_DIR=. nix run github:nix-gizmos/agent-vm#gemini
WORK_DIR=. nix run github:nix-gizmos/agent-vm#pi
```

### Install to PATH

```sh
# Claude Code (default)
nix profile install github:nix-gizmos/agent-vm

# Other agents
nix profile install github:nix-gizmos/agent-vm#gemini
nix profile install github:nix-gizmos/agent-vm#codex
nix profile install github:nix-gizmos/agent-vm#pi

# Now available everywhere
WORK_DIR=/path/to/project microvm-run
```

### As a flake input

Add as a dependency in another project's `flake.nix`:

```nix
{
  inputs.claude-vm.url = "github:nix-gizmos/agent-vm";

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

### Building on claude-microvm

A flake that needs a different guest — extra packages, its own NixOS
settings — builds it from a flavor rather than forking this repo:

```nix
{
  inputs.claude-vm.url = "github:nix-gizmos/agent-vm";

  outputs = { claude-vm, ... }:
    let system = "x86_64-linux"; in {
      packages.${system}.default = claude-vm.lib.mkRunner {
        inherit system;
        flavor = "claude";                    # one of claude-vm.lib.flavors
        modules = [
          ({ pkgs, ... }: {
            environment.systemPackages = [ pkgs.nodejs ];
            claude-vm.agent.mem = 12288;      # also the launcher's VM_MEM default
          })
        ];
      };
    };
}
```

| | |
|---|---|
| `lib.mkRunner { system, flavor ? "claude", modules ? [ ], nixosConfig ? … }` | The flavor's launcher, `microvm-run` with `microvm-stop` beside it, for the flavor's guest plus `modules`. The guest is on it as `.nixosConfig`. Without `modules` it is exactly `packages.<system>.<flavor>`. |
| `lib.mkNixosConfig { system, flavor ? "claude", modules ? [ ] }` | Only the guest, a `nixosSystem`; pass it to `mkRunner` as `nixosConfig` to build its launcher. |
| `lib.flavors` | The flavor names. |

`modules` come after everything this flake sets, so they can extend or
override any of it; the options meant for that are `claude-vm.*`
(`modules/base.nix`, `modules/cri.nix`) and `microvmPolicy.*`
(microvm-policy). The launcher takes its memory, vCPU and disk defaults from
the guest, so setting them there sets both. The agent name
(`claude-vm.agent.name`) must stay the flavor's: the launcher and the guest's
shares are wired by it, and `mkRunner` refuses a guest that renamed it.
Everything the launcher reads from the environment works as for the packaged
flavors.

### Extra shares

A flake built on a flavor can share more host directories into the guest,
beside `/work` and agent home: an input the guest may only read, or an
output directory it writes. The guest declares each one, since QEMU's devices
and the guest's mounts are fixed at build time; the launcher takes its host
directory at launch:

```nix
claude-vm.lib.mkRunner {
  inherit system;
  modules = [ {
    claude-vm.shares = {
      skill     = { mountPoint = "/skill"; };                        # read-only
      audit-out = { mountPoint = "/audit-out"; readOnly = false; };  # the guest writes it
    };
  } ];
}
```

```sh
SHARE_SKILL=~/skills/pinned SHARE_AUDIT_OUT=~/audits/project ./result/bin/microvm-run
```

- A share's host directory comes from `SHARE_<NAME>`, the name upper-cased
  with `-` as `_`. Every declared share must be given one, since QEMU expects
  its socket; the launcher refuses to start without it.
- Each gets its own `virtiofsd` in the launch's slice
  (`claude_microvm-<id>-share-<name>`), with files shown as the agent's. A
  read-only share — the default — runs with `--readonly`, which holds against
  root in the guest, and is mounted `ro`.
- None may overlap the launcher's own state, in either direction, read-only
  or not: `$XDG_DATA_HOME/<agent>-microvm` holds every project's agent home
  and the egress logs, `$XDG_RUNTIME_DIR/claude-microvm` every running
  launch's env file with its API keys, and an explicit `AGENT_HOME` has its
  `-egress`, `-cri` and `-store` siblings.
- No two shares may use the same mount point, and each is written in one
  canonical form: absolute, with no empty, `.` or `..` component and no
  trailing `/` (`/data`, not `/data/`, `/data/.` or `/./data`).
- Names are 1-16 of `a-z`, `0-9` and `-`; a mount point must stay clear of
  `/work`, `/home/agent`, `/run/microvm`, `/nix` and the system's own
  directories.

The session contract lists each share (a writable one in yellow), and
`instance.json` carries them under `shares`.

## Binary caches

microvm.nix builds QEMU as `qemu_kvm.override { nixosTestRunner = true; }` (its
`microvm.optimize.enable` default, which keeps the QEMU closure at ~845 MiB
instead of ~1.5 GiB). Since nixpkgs dropped `hostCpuOnly` from `qemu_test`
([NixOS/nixpkgs#541354](https://github.com/NixOS/nixpkgs/pull/541354), merged
2026-07-21) that exact combination is no longer built by Hydra, so it is **not
in `cache.nixos.org`**. Building it from source takes roughly 20 minutes, and it
recurs after every `flake.lock` bump that moves QEMU or its dependencies — not
just on first use.

These caches serve the prebuilt QEMU (~35 MiB download), and `flake.nix` declares
them in `nixConfig`:

| Cache | Who signs it | Populated by |
|-------|--------------|--------------|
| `nix-gizmos.cachix.org` | this project | every CI build of `.#claude`/`.#gemini`/`.#codex`/`.#pi` |
| `microvm-tools.cachix.org` | this project, while it was in the microvm-tools organization | CI builds until the move to nix-gizmos; no longer pushed to |
| `systemstart.cachix.org` | this project, before it moved to the microvm-tools organization | CI builds until that move; no longer pushed to |
| `microvm.cachix.org` | upstream [microvm.nix](https://github.com/microvm-nix/microvm.nix) | upstream CI (hits only when its nixpkgs pin matches ours) |

Substituters are a trust decision: a cache you enable can hand you any build
output it likes, signed with its own key. Pick whichever you prefer.

**Use the caches.** `nix build`/`nix run` (and `direnv reload`, via
`nix print-dev-env`) prompts once per setting, then offers to remember the
answer in `~/.local/share/nix/trusted-settings.json` — per user, keyed by the
exact value, not per repo:

```
do you want to allow configuration setting 'extra-substituters' to be set to
'https://nix-gizmos.cachix.org https://microvm-tools.cachix.org https://systemstart.cachix.org https://microvm.cachix.org' (y/N)?
```

**Answering the prompts is not enough on a multi-user install.** `substituters`
and `trusted-public-keys` are *restricted settings*: the client hands them to
`nix-daemon`, which drops them unless you are listed in `trusted-users`. Both
gates are independent, so accepting the flake config and still getting no cache
looks like this:

```
do you want to permanently mark this value as trusted (y/N)? y
warning: ignoring untrusted substituter 'https://nix-gizmos.cachix.org', you are not a trusted user.
warning: ignoring the client-specified setting 'trusted-public-keys', because it is a restricted setting and you are not a trusted user
```

The fix is daemon-side. Configure the caches system-wide — the narrower grant,
and it works no matter who runs the build:

```nix
# NixOS
nix.settings = {
  substituters = [ "https://nix-gizmos.cachix.org" "https://microvm-tools.cachix.org" "https://systemstart.cachix.org" "https://microvm.cachix.org" ];
  trusted-public-keys = [
    "nix-gizmos.cachix.org-1:a8qWp7lYufNBEKQEpJf54r0WVE0ksypqnFxOyemSlX4="
    "microvm-tools.cachix.org-1:OmNkdhRACxrceImh52cuegLuzJCj5hZFwFA8scRBk7A="
    "systemstart.cachix.org-1:hSTfDlXstyuVVukogR0sEmt8wJsaplp7NvisgUugNpE="
    "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys="
  ];
};
```

```conf
# non-NixOS: /etc/nix/nix.conf
extra-substituters = https://nix-gizmos.cachix.org https://microvm-tools.cachix.org https://systemstart.cachix.org https://microvm.cachix.org
extra-trusted-public-keys = nix-gizmos.cachix.org-1:a8qWp7lYufNBEKQEpJf54r0WVE0ksypqnFxOyemSlX4= microvm-tools.cachix.org-1:OmNkdhRACxrceImh52cuegLuzJCj5hZFwFA8scRBk7A= systemstart.cachix.org-1:hSTfDlXstyuVVukogR0sEmt8wJsaplp7NvisgUugNpE= microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys=
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

The host `WORK_DIR` is shared into the VM at `/work` using virtiofs. A `virtiofsd` daemon is started automatically as a systemd user service (`claude_microvm-<id>-work`, where `<id>` is the launch's random 12-hex-digit ID; see [Launch scope](#launch-scope)) — no root or sudo needed. It runs unprivileged in a user namespace with UID/GID translation so files created inside the VM are owned by your host user.

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

#### Work share caching

`WORK_CACHE` sets the `/work` virtiofsd's `--cache` policy: how long the guest
trusts its cached view of `WORK_DIR` before asking the host again. It only
matters when something outside the VM — the host, or another VM on the same
`WORK_DIR` — changes files there.

| `WORK_CACHE` | File contents | Attributes and directory entries |
|---|---|---|
| `never` | Not cached; every read and write goes to the host | Not cached |
| `auto` (default) | Re-read when a file is opened (close-to-open, as on NFS) | Cached for 1 second |
| `metadata` | Not cached | Cached for up to 24 hours |
| `always` | Kept across opens, with no time limit | Cached for up to 24 hours |

Under `never` and `metadata`, shared (`MAP_SHARED`) mappings of files on
`/work` fail — SQLite in WAL mode, for one. Private mappings, as git uses, work.

Two cases call for something other than the default:

- **VMs coordinating through a shared `WORK_DIR`: `never`.** Each VM has its
  own guest cache, so under any other policy one VM can act on a stale view of
  what another just wrote. `flock` and `fcntl` locks do not cross VMs under any
  policy — virtiofsd does not implement locking, so each guest kernel keeps its
  own. Coordinate through operations the host performs atomically instead:
  creating a lock file with `O_CREAT|O_EXCL`, `mkdir`, or `rename`. `never`
  makes each VM see the others' results immediately.
- **One VM that owns `WORK_DIR` exclusively: `always`,** for the fastest
  repeated reads and lookups, such as builds over large trees. Nothing else is
  expected to change `WORK_DIR` while the VM runs, the host included: if
  something does, the guest can keep serving old metadata for up to a day, and
  old file contents for as long as they stay in its cache — reopening the file
  does not refresh them.

### Home directory persistence

Agent state (sessions, credentials, settings) is stored in `$XDG_DATA_HOME/<agent>-microvm/<basename>-<hash>` (defaulting to `~/.local/share/<agent>-microvm/<basename>-<hash>`), where `<agent>` is the flavor name, `<basename>` is the first 12 chars of the project directory name, and `<hash>` is derived from the `WORK_DIR` path. Each agent has its own isolated home directory. All instances of the same agent on the same project share this directory automatically. To use a different directory, set `AGENT_HOME` explicitly:

```sh
AGENT_HOME=~/.my-agent-home make claude.run
```

This mounts the host directory at `/home/agent` inside the guest via a second virtiofs share with the same unprivileged UID/GID mapping.

To start from an empty agent home instead, and leave none behind, set
`AGENT_HOME_MODE=ephemeral`:

```sh
AGENT_HOME_MODE=ephemeral make claude.run
```

The launch then gets one of its own,
`$XDG_DATA_HOME/<agent>-microvm/.ephemeral/<id>/home` (the launch ID; on disk,
since agent homes hold caches that run to gigabytes), and it is removed when
the launch ends, together with what would otherwise sit beside the project's
home: the CRI image and the store disk. Nothing the guest wrote there — shell
rc files, agent settings and hooks, skills, a container image cache — reaches
the next launch. The egress logs are the exception, on purpose: they go to the
project's usual `<basename>-<hash>-egress`, the record of what each launch did.
A launcher killed outright leaves its directory behind; the next ephemeral
launch of the same flavor removes every one whose launch is no longer running.

It cannot be combined with `AGENT_HOME` (the launch picks the directory), nor
with `DIRENV_ALLOW=1`: the dev shell's guard against evaluating Nix files a
guest rewrote remembers its last evaluation in agent home, and a fresh one
would let every evaluation through unprompted. It also refuses a `WORK_DIR` that
contains its own state (`$XDG_DATA_HOME/<agent>-microvm`, or `AGENT_HOME`'s
parent), such as `WORK_DIR=$HOME` or `/`, and one that lies inside
`$XDG_DATA_HOME/<agent>-microvm` (its `.ephemeral` directory, a launch's home):
either way the guest could write the egress logs and other launches' homes. A persistent launch is only warned about that
layout, which it always allowed. A `WORK_DIR` that contains or lies inside
`$XDG_RUNTIME_DIR/claude-microvm`, where every running launch keeps its env file
and API keys, is refused in either mode. Signing in by OAuth leaves
nothing to reuse either, so ephemeral homes go with an API key.

### Per-launch instance directory

Each launch keeps what is its alone in one directory under the runtime dir:

```
$XDG_RUNTIME_DIR/claude-microvm/          one root for every flavor
  vms/<id>/                               this launch; owner-only; <id> is 12 hex digits
    guest/                                exported read-only at /run/microvm
      env  ca-certs/  nix-db.sqlite
    instance.json                         what this launch is (see below)
    lock                                  held while the launch runs
    qmp.sock                              QEMU's QMP control socket
    work.sock  agent-home.sock  guest.sock    the three virtiofsd sockets
    egress.port  egress.json              EGRESS_POLICY=shadow|enforce
```

Only `guest/` reaches the guest. It holds what the launch hands the guest,
which used to live in agent home — a directory shared by every launch on the
project and writable from each guest:

| in the guest | what |
|---|---|
| `/run/microvm/env` | the values the launcher passes in — API keys, `EXTRA_ENV`, `ENABLE_CRI`, the egress settings — sourced by the agent's shell and read as data by the guest's services |
| `/run/microvm/ca-certs/` | `EXTRA_CA_CERTS` |
| `/run/microvm/nix-db.sqlite` | the snapshot of the host's Nix database the guest imports at boot |

Its virtiofsd runs with `--readonly`, so nothing in the guest — root included —
can change these files, and two VMs on the same project each see only their
own. The runtime dir is tmpfs, so the env file's API keys never reach a disk.
The directory is removed when the launch exits, whether the VM shut down,
failed or never started; if the launcher itself is killed, what is left goes
at logout or reboot. `claude-microvm/` and `vms/` themselves stay, empty,
until then: launches share them, and one exiting must not remove them from
under one starting. Launchers before this kept the guest's three files in
agent home as `.microvm-env`, `.microvm-ca-certs` and `.microvm-nix-db.sqlite`;
the first launch that has this removes them.

Once written, the launch's files are read-only on the host too — everything in
`guest/`, `instance.json` and `lock` (files 0400, directories 0500) — so an
editor or a stray redirect cannot change them by accident, and
`instance.json` is put in place whole. Removing a directory a killed launcher
left behind therefore takes `chmod -R u+w` first. Nothing here stops a
deliberate change by your own user, and nothing needs to: `microvm-stop` takes
a launch's QMP socket from the layout (`vms/<id>/qmp.sock`), not from
`instance.json`, and refuses an `instance.json` whose `id` is not its
directory's name.

A launch's directory is named by its ID alone, like its systemd units, so a
tool with an ID has the path: `$XDG_RUNTIME_DIR/claude-microvm/vms/<id>/`.
`instance.json` there says what the launch is — its project, flavor, sockets
and units:

```sh
jq . "$XDG_RUNTIME_DIR"/claude-microvm/vms/*/instance.json
# {"version":1,"pid":…,"flavor":"claude","vmId":…,"id":…,"started":…,
#  "work":…,"agentHome":…,"guest":…,"guestMount":"/run/microvm",
#  "egressPolicy":"open",
#  "sockets":{"qmp":…,"work":…,"agentHome":…,"guest":…},
#  "slice":"claude_microvm.slice",
#  "units":{"scope":…,"work":…,"agentHome":…,"guest":…,"egress":null}}
```

`units` are the `systemctl --user` units the launch runs (see
[Launch scope](#launch-scope)); `egress` is set only under
`EGRESS_POLICY=alert|shadow|enforce`, which run something on the host, and
`scope` is null if the launch could not have one.

The QMP socket gives full control of the VM, e.g.
`echo '{"execute":"qmp_capabilities"}{"execute":"query-status"}' | socat - UNIX-CONNECT:<qmp.sock>`.
microvm.nix's own `microvm-shutdown` and `microvm-balloon` helpers still look
for a relative `claude-vm.sock`, so they do not work with this launcher; use
`microvm-stop` (below) to stop a VM.

The launcher refuses to start without a runtime dir (`XDG_RUNTIME_DIR`, or
`/run/user/<uid>`), or with one long enough to push a socket path past the
107-byte limit.

### Stopping a VM from outside

`microvm-stop` ships beside `microvm-run`, in the same `bin/` — it is not put
on your `PATH`. From the checkout, `make` runs it:

```sh
make vms                       # the running launches: ID, start, flavor, terminal, project
make stop ID=<id>              # press the VM's power button and wait for it to go
make stop                      # the same, for the only running launch
make stop ID=<id> FORCE=1      # stop QEMU at once, with no shutdown in the guest
```

or directly: `./result/bin/microvm-stop` after `make claude` (any flavor's
build stops any flavor's launch), `nix run .#microvm-stop -- <id>`, or the full
path the session contract prints on its `stop:` line, beside the launch's ID.

```sh
microvm-stop --list            # = make vms
microvm-stop <id>              # = make stop ID=<id>
microvm-stop --force <id>      # = make stop ID=<id> FORCE=1
```

With several launches on one project, the list tells them apart by start time
and by the terminal each launcher runs in: `tty` in every terminal you can
still type into names those, and a hung one is the terminal left over.

It presses the power button over the launch's QMP socket, so the guest shuts
down cleanly and the launcher then cleans up as after any VM exit. It waits
until the launch has gone (60 s by default, `--timeout` to change), and
says so if the guest ignores the button — `--force` is for that case. It works
the same for every launch, with a [launch scope](#launch-scope) or without.

### Wall-clock limit

`VM_TIMEOUT` stops the VM after a fixed time, for runs nobody watches:

```sh
VM_TIMEOUT=3h make claude.run           # seconds, or with s, m or h
VM_TIMEOUT=3h VM_TIMEOUT_GRACE=2m …     # how long the guest gets to shut down (default 60s)
```

When the time is up the launcher presses the VM's power button, as
`microvm-stop` does, so the guest shuts down cleanly; a guest still running
`VM_TIMEOUT_GRACE` later is stopped with QEMU's `quit`. The launch then exits
**124**, as `timeout(1)` does, so a caller can tell a run that was cut short
from one that ended on its own. The limit counts from the VM's start, not the
launcher's, and holds even if the launcher itself is killed outright: the
watcher keeps going as long as QEMU runs, and ends as soon as it does. The
session contract shows the limit, and `instance.json` carries it as
`timeout: {seconds, graceSeconds}` (`null` without one).

### Launch record

`LAUNCH_RECORD=<file>` has the launcher write what the launch actually ran
with, as JSON, for whatever drives it — a script checking that a run was as
contained as it meant it to be, rather than trusting the settings it passed:

```sh
LAUNCH_RECORD=~/runs/42.json EGRESS_POLICY=enforce EGRESS_BUILTIN=0 make claude.run
jq '.egress, .ended' ~/runs/42.json
```

It is written just before the VM boots and completed when the launch ends:

| key | what |
|---|---|
| `id`, `flavor`, `booted` | the launch ID, the flavor, when the VM started |
| `workspace` | `dir`, `mode` (`passthrough`/`ephemeral`), `guard` |
| `agentHome` | `dir`, `mode` (`persistent`/`ephemeral`) |
| `shares`, `timeout`, `resources` | as in `instance.json`; memory and vCPUs as passed |
| `egress` | `policy`, `builtinAllowlists`, `deny`; the session `allowlist` (`file`, `sha256`) and `auditLog` (null when `open`/`monitor` have none); the model `endpoints` the proxy serves, with their path grants and `usage` (the token parser, or null) (sealed modes); `usageFile`, and `apiBudget` (`maxRequests`, `maxTokens`; null without `API_BUDGET_*`) |
| `env` | the names — never the values — of the API keys and `EXTRA_ENV` passed in, and `devShellFromHost` (`DIRENV_ALLOW=1`) |
| `ended` | `null` until the launch ends; then `at`, `exitStatus` (124 if `VM_TIMEOUT` cut it short), `timedOut`, `egressDecisions` (`allow`/`deny`/`wouldDeny`/`overBudget` counts from the audit log; null outside shadow/enforce), `apiUsage` (per model endpoint: `requests`, `refused`, `tokens` by kind, `unknownUsage`, `budget`, `exhausted` — the proxy's usage file; null outside shadow/enforce), and `egressVerdict` (see below; null outside shadow/enforce) |

A record whose `ended` is still `null` after the launcher has gone is one whose
launcher was killed. A record already at the path is removed when the launcher
starts, so a launch that is refused before boot leaves none, rather than the
previous run's. The file is owner-only and replaced whole on each write, from a
fresh file of its own. It may not be anywhere the guest can write — inside
`WORK_DIR`, this launcher's state (`$XDG_DATA_HOME/<agent>-microvm`),
`AGENT_HOME`, or a writable share; a symlinked parent is followed to where the
file would really be — and its directory must be yours and writable by no one
else (so not `/tmp`). Those checks come before anything is removed: a path that
is refused keeps whatever file it held.

A record that cannot be written stops the launch before the VM boots: no
evidence, no run. A record that cannot be completed at exit is reported on
stderr and keeps `ended: null`; the launch then never exits 0 — a non-zero VM
status (124, say) is kept, and a clean run exits 1.

For a sealed run (`EGRESS_POLICY=shadow` or `enforce`) the launcher judges the
audit log at exit with microvm-policy's `egress-report verdict`, prints its
one-line verdict, keeps the whole of it beside the audit log
(`session-<…>.verdict.txt`, `latest.verdict.txt`), and records it as
`ended.egressVerdict`:

```json
{"outcome": "not-clean",
 "summary": "egress verdict: NOT CLEAN — 1 decision(s) other than an allowed model-API request; 12 model-API request(s) allowed",
 "details": ["1  deny connect evil.example.com:443"]}
```

`outcome` is `clean` only when every decision was an allowed request to a
model-API endpoint — an allowed tunnel counts against the run as much as a
denied one, and so does a shadow `would_deny` or a request refused past the [API budget](#api-budget) (`over_budget`). Otherwise it is `not-clean`,
`invalid` (a line in the log is not a proxy decision), `missing` (no log), or
`error`; `details` names each other decision with its count. Only a run that
keeps a record is judged — with the built-in allowlists on, an ordinary
session is expected to use them — and the verdict never changes the exit
status: what a run that is not clean means is up to whoever reads the record.
For a run that should reach nothing but the model, launch with
`EGRESS_POLICY=enforce EGRESS_BUILTIN=0`.

### Launch scope

Each launch's systemd user units share one name, `claude_microvm-<id>`, and a
slice of their own, nested in `claude_microvm.slice`:

```
claude_microvm.slice
  claude_microvm-<id>.slice                 one launch
    claude_microvm-<id>.scope               the launcher and QEMU
    claude_microvm-<id>-work.service        virtiofsd for /work
    claude_microvm-<id>-agent-home.service  virtiofsd for agent home
    claude_microvm-<id>-guest.service       virtiofsd for the read-only guest share
    claude_microvm-<id>-egress.service      the egress proxy or follower, when the policy runs one
```

The scope holds the VM's processes, and the slice the whole launch, so each
is accounted together. The unit names carry only the ID — the slice does not
namespace them, and the ID is what keeps two launches apart — and each unit's
description says what it is and for which project, which is what
`systemctl --user list-units` shows beside it:

```sh
systemctl --user status claude_microvm.slice          # every running VM and its daemons
systemctl --user status claude_microvm-<id>.slice     # one launch
systemctl --user stop claude_microvm-<id>.slice       # hard stop of a scoped launch; the launcher still cleans up
journalctl MICROVM_ID=<id>                            # every daemon's log for one launch
```

Stopping the slice kills QEMU outright, with no shutdown in the guest, like
`microvm-stop --force`. Without a scope it would also go wrong: the launcher
and QEMU are not in the slice then, so it would stop only the daemons and
leave the VM running on shares that have gone. Prefer `microvm-stop`.

A launch's slice is made on first use and, once empty, stays until logout —
whether a launch is still running is for `instance.json` and its lock to say,
not the slice.

The binding is what keeps a killed launcher from leaving its daemons behind.
The launcher's cleanup stops them on any normal exit, `systemctl stop`, or a
closed terminal, but nothing runs it on `SIGKILL` (or the OOM killer). systemd
then stops the daemons itself once the scope empties — that is, once QEMU has
exited too, since a VM that outlives its launcher still needs its shares. Its
instance directory is left in the runtime dir in that case, and goes at logout
or reboot.

If systemd refuses the launcher a scope — systemd 261 grants one from a login
session and even from a system service, but other versions and setups may
not — the launch goes ahead without one, with a warning: its daemons are then
in its slice but not bound to anything, and `microvm-stop` is the way to stop
it.

### Sandboxing

The VM provides strong isolation from the host:

- **Filesystem** — only `/work` and the home directory are shared read-write; everything else is VM-local and ephemeral
- **Nix store** — the host's `/nix/store` is shared as the lowerdir of the guest's store overlay, exported `readonly=on` so the guest cannot write through it
- **Processes** — completely isolated (separate kernel)
- **Network** — QEMU user-mode NAT; the VM can reach the internet but can't bind host ports. `EGRESS_POLICY=monitor|alert` records everything the guest talks to from the host side; `EGRESS_POLICY=shadow|enforce` seals the netdev behind a host-side proxy that holds the API keys — see [Egress policy](#egress-policy)

Every launch prints a **session contract** before boot: project path and mount
mode, agent home, the [guest share](#per-launch-instance-directory) and what
this launch put in it, whether the dev shell evaluated the project's Nix code
on the host, workspace guard, egress mode, which env vars reach the guest
(names only, never values), container state, resources, and the launch's ID
with the command that stops it — so what a run can reach is
visible while it is still cheap to stop. Each row carries a status dot (green:
contained, yellow: worth knowing, red: the host is exposed) and a hint at the
knob that changes it; colour is off without a terminal or with `NO_COLOR` set.

In `alert`/`shadow`/`enforce` it also lists every egress rule, highest
precedence first: `EGRESS_DENY`, then each allow source (`EGRESS_ALLOW`,
`EGRESS_ALLOWLIST`, the built-in lists) with all of its entries, then what
happens to everything else. Entries an `EGRESS_DENY` removed are marked `✗`
in their source; a broader entry that keeps a denied domain reachable is
marked `⚠`.

#### Hardening notes

Three things worth knowing before pointing this at code you don't trust:

- **`DIRENV_ALLOW=1` evaluates the work directory's Nix code on the host.** The dev
  shell cache runs `nix print-dev-env` (or `devenv print-dev-env`) against
  `$WORK_DIR` *outside* the VM, before boot. Since the guest can write `/work`,
  a `flake.nix` or `devenv.nix` modified during a session would be evaluated on
  the host on the next launch — a guest-to-host path that needs no kernel bug.
  The launcher therefore fences it: when the Nix files changed since the last
  evaluation, it prompts before evaluating (and refuses in non-interactive
  runs); `DIRENV_REEVAL=1` skips the prompt deliberately. A first-time
  evaluation — your own fresh `DIRENV_ALLOW=1` — proceeds without one. Still:
  don't combine `DIRENV_ALLOW=1` with a `WORK_DIR` whose contents you wouldn't
  run on the host yourself.
- **The guest can write workspace paths whose contents execute on the host
  later** — `.git/hooks`, `.git/config`, the hook directories and managers a
  `core.hooksPath` can point at (`.githooks`, `.husky`,
  `.pre-commit-config.yaml`), `.mcp.json`, `.claude/commands`,
  `.claude/agents`, `.claude/settings.json` and `.claude/settings.local.json`
  (their hooks), `.vscode` (tasks), `.envrc`. A compromised session that
  writes those persists code past the VM teardown: it runs in the next
  host-side `git` commit or push, editor task, or unsandboxed agent session.
  `WORKSPACE_GUARD=1` makes the ones that exist at
  boot read-only inside the guest (kernel-enforced bind mounts the agent user
  cannot undo). Opt-in for now because denial breaks a workflow this project
  itself uses — asking the agent to write a project skill or register an MCP
  server. It cannot protect a file that does not exist yet; the session
  contract states the guard's state either way.
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

ctrl+z suspends the agent to a shell prompt on the VM's console: `fg` brings
it back, and `exit` (twice — bash warns about the stopped job first) powers the
VM off. Only the console's own login shell runs the agent; a `bash -i` or
`bash -l` started inside the VM, by you or by the agent, is an ordinary shell
that starts no second agent and powers nothing off when it ends.

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

### Egress policy

By default the VM has unrestricted outbound access (`EGRESS_POLICY=open`). Two
observe-only modes record what the guest talks to, without blocking anything:

```sh
# Observe all guest traffic; per-domain summary printed at session end
EGRESS_POLICY=monitor make claude.run

# Same, plus live alerts for destinations outside the allowlist
EGRESS_POLICY=alert make claude.run
```

Both attach a packet capture to the VM's network device **on the host side** —
rootless, and the guest cannot see, avoid, or tamper with it. Each packet is
truncated (`EGRESS_PCAP_MAXLEN`, default 4096 bytes): enough for headers, DNS
and a complete TLS ClientHello — post-quantum hybrid key exchange pushes those
to ~1.8 KiB, and SNI extraction needs the whole thing — while bulk transfers
(TSO super-frames of up to 64 KiB) still truncate to 4 KiB each. When the session ends, a summary is printed and saved under
`<agent-home>-egress/` (a host-only directory, never shared into the guest),
and the raw capture is deleted — set `EGRESS_KEEP_PCAP=1` to keep it.

All egress files live in a host-only sibling of the agent home,
`~/.local/share/<agent>-microvm/<project>-<hash>-egress/`, one set per
session (`session-<timestamp>-<id>.{report.txt,alerts.log,allowlist}`). The
launch banner names the exact paths, but since that scrolls away once the
agent takes the console, the directory also keeps stable symlinks to the
current session — so from anywhere on the host:

```sh
tail -f ~/.local/share/claude-microvm/*-egress/latest.alerts.log
cat     ~/.local/share/claude-microvm/*-egress/latest.report.txt
```

`alert` additionally matches every observed hostname (DNS queries and TLS SNI)
against an allowlist, live, one line per newly seen off-list domain in the
alerts log. The effective allowlist is the sum of

- the baked-in default — the agent's own endpoints plus common development
  infrastructure (registries, caches, container registries); see
  `modules/egress/`. Deliberately generous: the point is surfacing
  *unexpected* destinations, not cataloguing npm installs;
- an optional org/project file, `EGRESS_ALLOWLIST=/path/to/file`;
- per-session additions, `EGRESS_ALLOW=foo.example.com,bar.example.net`.

Per-session removals, `EGRESS_DENY=datadoghq.com,browser-intake-us5-datadoghq.com`,
drop every entry (from any of the three) that is a listed domain or one of its
subdomains — e.g. to keep Claude Code's optional telemetry from leaving the
VM in shadow/enforce. The format has no deny rule, so a domain still covered by
a broader entry (`api.anthropic.com` under `anthropic.com`) cannot be removed;
the launcher warns instead of claiming it is blocked.
Nor does a deny reach the agent's model endpoints under `shadow`/`enforce`:
the proxy serves them under their own path grant, not as allowlist entries, so
`EGRESS_DENY=anthropic.com` leaves `/v1/messages` working, and the contract
and a warning say so.

`EGRESS_BUILTIN=0` leaves the baked-in default out altogether, so the
allowlist is only what `EGRESS_ALLOWLIST` and `EGRESS_ALLOW` name — with
neither, nothing. That is the setting for running code you do not trust
under `enforce`: by default the guest can still reach GitHub, the package
registries and the Nix cache. The agent keeps working: its model API is not an
allowlist entry but a reverse-proxied endpoint with its own path grant, which
this does not touch. What the agent loses is everything else it talks to
(update checks, telemetry, plugin installs); with Claude Code,
`EXTRA_ENV=CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` keeps it from trying.
The session contract says when the built-in lists are off. Under `alert`, which
only watches and has no proxy, the model API is an ordinary destination: with
the built-ins off, the agent's own API traffic alerts too unless
`EGRESS_ALLOW` names its host.

An entry matches itself and every subdomain. Alerts never block — a flagged
domain is a line in a log and in the session-end report, nothing more.

One caveat on the observe modes: attribution is DNS- and SNI-based, so
traffic to a hardcoded IP (or with an encrypted ClientHello) appears as
`ip:port` under "no observed hostname" rather than by name.

#### Sealed modes: shadow and enforce

```sh
EGRESS_POLICY=shadow  make claude.run   # sealed netdev; the proxy allows all and audits
EGRESS_POLICY=enforce make claude.run   # sealed netdev; the allowlist is enforced
```

Both seal the VM's network (`restrict=on`): every flow is refused except one
hole that leads to a proxy on the host (`packages.egress-proxy` — Go stdlib
only, from [microvm-policy](https://github.com/nix-gizmos/microvm-policy)).
The guest gets `HTTP(S)_PROXY` pointing at it, and:

- **API keys never enter the guest.** The agent's `*_BASE_URL` points at the
  proxy, which originates genuine TLS to the real API, validates its real
  certificate (no interception, no CA in the guest trust store), strips any
  client-supplied credential, and injects the key held on the host. The
  guest sees only a placeholder. Under subscription/OAuth login the client
  mints its own token, which the proxy passes through — that mode keeps a
  token in the guest, and the full credential guarantee applies to API-key
  mode only.
- **The API path allowlist is a capability grant**: only the inference
  endpoints are reachable by default (even with a valid key,
  `api.anthropic.com` is an exfiltration channel via its upload endpoints).
  Claude gets exactly `/v1/messages` and `/v1/messages/count_tokens`, not
  the batches API below them, which stores results for later retrieval.
- **Everything else is an opaque `CONNECT` tunnel**, never decrypted,
  checked against the same tiered allowlist as `alert` — with one addition:
  an entry may grant a port, e.g. `github.com:22` for git over SSH (ssh is
  wired through the proxy automatically; a bare entry grants 443 only).
- **DNS exists only at the proxy.** The guest boots with an empty
  `resolv.conf` in these modes, so a blocked lookup fails instantly instead
  of hanging; UDP (and so QUIC) is gone entirely, and clients fall back to
  TCP.
- **The seal is verified at boot**: the guest checks that the proxy answers,
  then tries a direct connection to the proxy's host listener (`10.0.2.2`),
  which only the seal can block. It refuses to start the agent if that
  connection succeeds, or if the proxy doesn't answer and so the result
  proves nothing (override with `EXTRA_ENV=EGRESS_SEAL_IGNORE=1`).
- Decisions land in `latest.audit.jsonl` (same directory as the reports),
  one JSONL line each: `allow`, `deny`, or — in shadow mode — `would_deny`,
  which is how you find what enforce would break before switching. A session
  summary prints at exit.

Worth knowing: a denied `CONNECT` shows up in tools only as "403 from
proxy" — the actionable reason is in the audit log. Tools that ignore
`HTTPS_PROXY` fail with an instant connection-refused in both sealed modes
(that discovery is what shadow is for). `ENABLE_CRI` container daemons are
pointed at the proxy too, so image pulls work in the sealed modes — the
registry hosts in the default allowlist (`docker.io`, `ghcr.io`, `quay.io`,
`registry.k8s.io`) decide what resolves, and a pull from elsewhere is a
`deny` in the audit log, not a hang. And ping to `10.0.2.2`/`10.0.2.3` is
still answered locally by slirp even when sealed — "ping works" is not
evidence the host is reachable. A corporate upstream proxy chains
automatically via the
host's own proxy environment. Claude Code's WebSearch and WebFetch tools
execute server-side on Anthropic's infrastructure, so they appear here only as
traffic to `api.anthropic.com`.

#### API budget

In the sealed modes the proxy also counts what the session spends on the model
API, and can cap it:

```sh
EGRESS_POLICY=enforce API_BUDGET_TOKENS=2000000 API_BUDGET_REQUESTS=300 make claude.run
```

- **Each limit applies to each model endpoint, for this launch.**
  `API_BUDGET_REQUESTS` counts requests. `API_BUDGET_TOKENS` counts input,
  cache-creation, cache-read and output tokens together, read from the
  responses as they pass. Past either limit the proxy answers
  `403` — not `429`, which the clients would retry — with a message that the
  budget is spent, and logs `over_budget` in the audit log, in `shadow` as in
  `enforce`.
- **Tokens are only counted for Anthropic's API** (claude, and pi's
  `/anthropic`). On gemini and codex `API_BUDGET_TOKENS` is refused at launch;
  `API_BUDGET_REQUESTS` caps them. For pi, the token limit caps `/anthropic`
  only; the request limit caps all three endpoints.
- **The limit is checked before a request goes upstream.** A request already
  under way finishes, so a session can end a little over `API_BUDGET_TOKENS`
  — by what its last concurrent requests returned. A stream cut short is
  charged what the API had reported by then. A request that never reached the
  API spends nothing.
- **Under `API_BUDGET_TOKENS` the meter fails closed.** A successful response
  whose usage the proxy cannot read counts as `unknownUsage` in the usage
  file and ends the token budget, since the spend is no longer known. (Message
  batches, whose cost only shows later, are outside Claude's path grant.)
- **Without a budget the spend is still recorded.** Each launch writes
  `session-<…>.usage.json` (`latest.usage.json`) beside the audit log, kept
  current after every response, and the session summary at exit has a line
  per endpoint: `api /anthropic: 41 requests, 1830412 tokens`.
- **A budget outside the sealed modes is an error**, not a warning: it is
  the proxy that enforces it, and a spending limit that silently does nothing
  is worse than none.

A practical rollout for a team: run `monitor` over real workloads first, build
the org allowlist from the reports (they live in `<agent-home>-egress/`), then
switch the default to `alert` — each step changes observability, never
behavior.

### Ephemeral workspace

```sh
WORKSPACE_MODE=ephemeral make claude.run
```

Mounts a guest-side overlay over `/work`: the agent sees a writable project,
but nothing it writes reaches the host — the session's delta lives in RAM and
vanishes at poweroff. This inverts the default contract (passthrough, where
edits appear on the host instantly), so it stays opt-in; use it for code you
don't trust, or for experiments you want to inspect before accepting.

Inside the VM, `vm-work-diff` lists what the session changed (`--patch` for
a unified diff), and anything worth keeping is copied to `/home/agent`, which
remains a persistent host share. Two things to know: writes to `/work` cost
VM memory in this mode (the upper layer is a tmpfs), and the host-side
tooling that reads the project before boot (`DIRENV_ALLOW` caching, settings
seeding) sees the pristine host state, as before.

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

> Values are written to `/run/microvm/env` (mode `400`, on the read-only
> [instance share](#per-launch-instance-directory)) and are readable by the agent
> and by root in the guest. Nothing in the guest can change them, and the
> guest's root services never source the file: they read only the keys they
> need, as plain text.

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
| `AGENT_HOME_MODE` | `persistent` (one agent home per project, kept) or `ephemeral` (a fresh one for the launch, removed with its CRI and store images when it ends; egress logs kept) — see [Home directory persistence](#home-directory-persistence) | `persistent` |
| `SHARE_<NAME>` | Host directory for each share the guest declares in `claude-vm.shares` (flakes built with `lib.mkRunner`), the name upper-cased with `-` as `_`; required for every declared share — see [Extra shares](#extra-shares) | — |
| `WORK_CACHE` | virtiofsd cache policy for `/work`: `auto`, `always`, `never` or `metadata` — see [Work share caching](#work-share-caching) | `auto` |
| `AGENT_SETTINGS` | Host path to a settings file seeded into the agent home before boot (flavor-specific destination, e.g. `.claude/settings.json`) — see [Pre-seeding agent settings](#pre-seeding-agent-settings) | (none) |
| `VM_MEM` | VM memory in MB | `8192` |
| `VM_VCPU` | VM vCPU count | `4` |
| `VM_TIMEOUT` | Wall-clock limit on the VM, in seconds or with an `s`/`m`/`h` suffix: then the power button, `quit` after `VM_TIMEOUT_GRACE`, and exit status 124 — see [Wall-clock limit](#wall-clock-limit) | `0` (none) |
| `VM_TIMEOUT_GRACE` | How long the guest gets to shut down once `VM_TIMEOUT` is up, before QEMU is stopped | `60` |
| `LAUNCH_RECORD` | File to write a JSON record of what the launch ran with, before boot, and how it ended, at exit — see [Launch record](#launch-record) | (none) |
| `DIRENV_ALLOW` | Set to `1` to load the project's dev shell (flake.nix or devenv) into the agent's environment | `0` |
| `DIRENV_REEVAL` | Set to `1` to re-evaluate changed project Nix files on the host without the interactive prompt (see [Hardening notes](#hardening-notes)) | (prompt) |
| `WORKSPACE_GUARD` | Set to `1` to make host-executed workspace config paths (`.git/hooks`, `.githooks`, `.mcp.json`, `.claude/settings.json`, …) read-only inside the guest | (off) |
| `WORKSPACE_MODE` | `passthrough` (edits appear on the host instantly) or `ephemeral` (guest-side overlay: writes stay in the VM, `vm-work-diff` lists them, all is discarded at poweroff) — see [Ephemeral workspace](#ephemeral-workspace) | `passthrough` |
| `NO_PAUSE` | Set to `1` to boot immediately instead of waiting for Enter on the session contract (the contract still prints). **The wait is the default since v0.16.0**: set this for any automation that runs the launcher on a terminal (tmux, `expect`, `script`, IDE tasks). Already skipped when stdin is not a terminal (pipes, cron); a one-shot `AGENTS_ARGS=-p …` run from a terminal still waits | (pause) |
| `ENABLE_CRI` | Comma-separated list of container runtimes to activate: `containerd`, `crun`, `crio`, `docker`, `podman` | (disabled) |
| `CRI_STORAGE_SIZE` | Cap on the CRI storage disk in MiB, applied when the image is first created. Sparse, so it is a ceiling rather than an allocation. `0` runs without the disk entirely. The disk is only *created* when `ENABLE_CRI` is set — see [Container runtime support](#container-runtime-support) | `30720` (30 GiB) |
| `VM_STORE_SIZE` | Cap on the writable Nix store disk in MiB. Sparse, and recreated on every launch, so it applies to every run. Minimum 1024; `0` is rejected — see [Leaving nothing on the host](#leaving-nothing-on-the-host) | `10240` (10 GiB) |
| `ANTHROPIC_API_KEY` | API key for Claude Code (claude flavor) | — |
| `GEMINI_API_KEY` | API key for Gemini CLI (gemini flavor) | — |
| `OPENAI_API_KEY` | API key for Codex CLI (codex flavor) and Pi (pi flavor) | — |
| `EXTRA_CA_CERTS` | Path to a PEM file or directory of PEM files containing custom CA certificates to trust inside the VM | (system CAs only) |
| `EGRESS_POLICY` | `open` (unrestricted), `monitor` / `alert` (observe-only: record all guest traffic, `alert` adds live off-allowlist alerts), `shadow` / `enforce` (sealed netdev, all traffic through the host-side proxy; `shadow` audits what `enforce` would deny, `enforce` denies it and keeps API keys out of the guest). See [Egress policy](#egress-policy) | `open` |
| `EGRESS_ALLOW` | Extra allowlist domains for `alert`/`shadow`/`enforce`, comma-separated. An entry matches itself and every subdomain; `host:port` grants a non-443 port | (none) |
| `EGRESS_ALLOWLIST` | Path to an additional allowlist file (org or project policy), appended to the baked-in default for `alert`/`shadow`/`enforce` | (none) |
| `EGRESS_BUILTIN` | `0` leaves the baked-in allowlists out for `alert`/`shadow`/`enforce`: only `EGRESS_ALLOWLIST` and `EGRESS_ALLOW` apply, and the agent's model endpoints, which are no allowlist entry. See [Egress policy](#egress-policy) | `1` |
| `EGRESS_DENY` | Allowlist domains to remove for `alert`/`shadow`/`enforce`, comma-separated: drops each entry that is a listed domain or below one, after all additions. Cannot narrow a broader entry (warns instead) | (none) |
| `API_BUDGET_REQUESTS` | Requests the session may send to each model endpoint in `shadow`/`enforce`; past it the proxy refuses them (403). See [API budget](#api-budget) | (none) |
| `API_BUDGET_TOKENS` | Tokens (input, cache and output together) the session may spend on each model endpoint in `shadow`/`enforce` — Anthropic's API only; refused on gemini and codex. See [API budget](#api-budget) | (none) |
| `EGRESS_KEEP_PCAP` | Set to keep the raw capture after the summary is written; by default it is deleted and only the report persists | (unset) |
| `EGRESS_PCAP_MAXLEN` | Captured bytes per packet in `monitor`/`alert` | `4096` |
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
| `$XDG_RUNTIME_DIR/claude-microvm/vms/<id>/` (env file with API keys, CA certs, nix DB snapshot ~97 MiB; sockets) | per-run, on tmpfs, deleted on exit — or at logout/reboot if the launcher is killed | — |
| `$XDG_RUNTIME_DIR/claude-microvm/` and its `vms/`, empty | on tmpfs, until logout/reboot | — |
| `$AGENT_HOME` (agent state, dev-shell cache) | persistent | `AGENT_HOME_MODE=ephemeral`: a fresh one per launch, removed with its CRI and store images on exit (or by the next ephemeral launch if the launcher is killed) |
| `$AGENT_HOME-egress/` (egress logs, reports) | persistent, under `EGRESS_POLICY` other than `open`; also under `AGENT_HOME_MODE=ephemeral`, beside the project's home | delete it; `EGRESS_POLICY=open` writes none |

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
