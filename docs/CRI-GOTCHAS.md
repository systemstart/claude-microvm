# Container runtime gotchas in this microVM

How container runtimes are wired here, and the sharp edges around them. Each section leads with
the behaviour and names the error text it explains, so pasting an error into a search box finds
the right one.

## OCI runtime resolution: why `containerd.service` carries `runc` and `crun` on its PATH

`containerd-shim-runc-v2` resolves the OCI runtime by **PATH lookup** unless the runtime options
carry an absolute `BinaryName`. That makes the shim's inherited environment load-bearing, and it
differs per namespace:

- **CRI namespace** — `/etc/containerd/config.toml` sets `BinaryName = "${pkgs.runc}/bin/runc"`,
  so `crictl` and kubelet workloads never do a PATH lookup at all.
- **moby namespace** — Docker passes no `BinaryName`, so the shim falls back to PATH.
- **`default` namespace** (`ctr`, rootful `nerdctl`) — likewise no `BinaryName`, likewise PATH.

NixOS's default PATH for units is coreutils, findutils, gnugrep, gnused and systemd — no runc,
and nothing from `/run/current-system/sw/bin`. So `modules/cri.nix` puts the runtimes on the unit
explicitly, for both `containerd` and `containerd-crun`:

```nix
systemd.services.containerd.path = [ pkgs.runc pkgs.crun ];
```

`crun` is there so a container that requests that runtime by name resolves too.

### What this prevents

Without it, containers in the moby namespace fail to start while image pulls keep working:

```
docker: Error response from daemon: failed to create task for container: failed to create shim
task: OCI runtime create failed: unable to retrieve OCI runtime error (open
/run/containerd/io.containerd.runtime.v2.task/moby/<id>/log.json: no such file or directory):
exec: "runc": executable file not found in $PATH
```

`crictl` and everything on the CRI path keep working throughout, which makes it look like a
broken Docker install rather than a PATH problem.

The failure was also **start-order dependent**, which is worth knowing because it makes any
report of it hard to reproduce. Docker's containerd supervisor spawns its own containerd only if
one isn't already reachable:

| `ENABLE_CRI` | dockerd's containerd | PATH lookup |
|---|---|---|
| `docker` | spawns its own, from `${moby}/libexec/docker/` | succeeds — moby ships `containerd`, the shim and `runc` in one directory, and dockerd puts it on the PATH of what it spawns |
| `containerd,docker` | attaches to `containerd.service` | depends entirely on that unit's PATH |

With standalone Docker the tree is `dockerd (ppid 1)` with a `containerd --config
/var/run/docker/containerd/containerd.toml` child. Attached to `containerd.service`, dockerd has
no containerd child at all — both are ppid 1 — and its tasks appear under
`/run/containerd/io.containerd.runtime.v2.task/moby/`.

Verified 2026-08-25 on a VM booted with `ENABLE_CRI=containerd,docker`: containers run, under the
system containerd's shim. Swapping the unit PATH for a nonexistent directory via `systemctl edit
--runtime` reproduces the error above and reverting restores it, so the PATH is demonstrably what
carries this.

### Checking runtime resolution in a running VM

```sh
# what the shim will search — expect runc and crun store paths
systemctl show containerd -p Environment | tr ' ' '\n' | grep -E 'runc|crun'

# which containerd Docker is using: a containerd child of dockerd means its own,
# both at ppid 1 means it attached to the system one
ps -eo pid,ppid,comm | grep -E 'dockerd|containerd' | grep -v grep

# end to end
docker run --rm hello-world

# which containerd actually ran it — read the shim's argv for -namespace and -address.
# /run/containerd/io.containerd.runtime.v2.task/ is root-only, so don't try to ls it.
docker run -d --name probe busybox sleep 60
ps -eo pid,ppid,args | grep [c]ontainerd-shim
docker rm -f probe
```

### Still true

- **Which runc runs depends on start order.** Standalone Docker uses moby's bundled runc (1.3.6
  in the build this was traced on); attached to `containerd.service` it uses the store runc
  (1.4.3). Both work; they are not the same binary. Making it deterministic would mean
  `dockerd --containerd=/run/containerd/containerd.sock` plus `after`/`requires` on
  `containerd.service`, at the cost of `ENABLE_CRI=docker` implying containerd. Not done.
- **`docker info` misreports the runtime.** It probes through its own resolution and prints
  moby's bundled runc version while the shim executes the store's. Don't use it to tell which
  runc ran.
- **The `default` namespace is unproven.** The reasoning says `ctr` and rootful `nerdctl` need the
  same PATH and get it from the same fix, but neither client can be driven far enough to
  demonstrate that without root (see below). podman is unaffected either way — it never touches
  `containerd.service`.

Versions this was traced on: moby 29.6.2 (bundled runc 1.3.6), store runc 1.4.3, crun 1.27.1,
containerd 2.3.3.

## Debugging notes

Things that cost time to rediscover when poking at container runtimes from inside the VM.

- **Guest sudo is limited** to `systemctl`, `journalctl` and `poweroff` — no editing `/etc`, no
  running `dockerd`/`nerdctl`/`ctr` as root.
- **Socket access isn't the constraint; on-disk state is.** `/run/containerd/containerd.sock` is
  `srw-rw---- root:agent`, so clients connect fine, but
  `/run/containerd/io.containerd.runtime.v2.task/` and the snapshotter tree under
  `/var/lib/containers/` are root-only. Read container state off `ps` argv rather than `ls`.
- **`/etc/systemd/system` is a symlink into the read-only store**, so drop-ins must use
  `systemctl edit --runtime` (which writes to `/run/systemd/system/…` on tmpfs) and are undone
  with `systemctl revert --runtime`.
- **Restarting docker races the next command.** The first `docker` call after
  `systemctl restart docker` can report `dial unix /var/run/docker.sock: no such file or
  directory`. That's the daemon still coming up — wait for `systemctl is-active docker` and retry.
- **`nerdctl` as non-root always goes rootless**, whenever euid ≠ 0 and regardless of
  `--address`, so it never reaches the system containerd socket.
- **`ctr` reaches the daemon but can't start containers as the guest user.** It lists namespaces
  and pulls images fine; `ctr run` then fails on a client-side snapshotter path it can't read
  (`/var/lib/containers/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/N/fs:
  permission denied`) — earlier than any runtime lookup.
- **podman's units are `linked/ignored`** under `ENABLE_CRI=containerd,docker`. Start the socket
  first (`sudo systemctl start podman.socket`), or the CLI reports it can't connect and suggests
  `podman machine init`, which is a red herring here.
- **Evaluating this flake inside the VM may fail.** The microvm.nix input's store path can vanish
  from under a running VM (`does not exist`, while nix still considers it valid), and
  `builtins.getFlake "/work"` trips over the `claude-vm.sock` socket in the repo root. Evaluate
  on the host instead.
