# Nix store gotchas in this microVM

The guest's `/nix/store` is an overlay on the host's store, which makes it behave in ways that
surprise both nix and the people debugging it. Symptom first, so an error paste finds the section.

## `nix` wants to download paths that are already in `/nix/store`

### Symptom

`nix develop` (or `nix build --dry-run`) on a project flake reports hundreds of paths "will be
fetched" from `cache.nixos.org`, even though those exact store paths are present under
`/nix/store` and some are already on `$PATH`:

```
$ nix build --dry-run .#devShells.x86_64-linux.default
these 181 paths will be fetched (296.8 MiB download, 1.3 GiB unpacked):
  /nix/store/74sind1d6vf2bfwd7yklg8chsvzqxmmq-coreutils-9.10
  /nix/store/4b7jvqsqywnsb273svingfmpqschkszi-bun-1.3.11
  ...
```

The rootfs is a RAM-backed tmpfs of a few GiB, so a fetch of that size used to be roughly enough
to fill the disk and brick the VM. The writable half of the store now lives on its own disk
(see [Where the writable store lives](#where-the-writable-store-lives)), which absorbs the
damage — but the fetch is still pure waste, and the fix below is what stops it happening.

### Cause

`/nix/store` is an overlay — the host's store read-only via virtio-9p as the lowerdir, and a
writable upperdir for anything the VM writes (a disk volume today, the RAM-backed rootfs when
this was first written):

```
ro-store  on /nix/.ro-store  type 9p       (host store, read-only)
overlay   on /nix/store      type overlay  lowerdir=/sysroot/nix/.ro-store
                                           upperdir=/sysroot/nix/.rw-store/store
```

So the **files** of the host store are visible, which is why
`/nix/store/…-coreutils-9.11/bin/ls` runs without anything being copied.

But `/nix/var/nix/db/db.sqlite` is a **fresh local SQLite database** created at VM boot, and it
has no entries for any path exposed through the lowerdir. When nix asks "is path X valid in this
store?", it consults the DB, not the filesystem. The DB says no for everything from the host, so
nix substitutes X from the binary cache — and writing those bytes into `/nix/store/X` makes
overlayfs **copy the path up into the upperdir**, even though byte-identical content already
exists in the lowerdir.

Every "fetch" therefore charges the writable layer for the unpacked size of a path that was
already on disk.

### The hashes are not drifting

They are bit-identical to the host's, and there is no flake/lock skew. The mismatch is only
between the **filesystem** view of `/nix/store` (sees host paths via the lowerdir) and the **nix
database** view (knows only what the VM registered since boot).

## Fix: import the host's DB at launch

Four pieces, all shipped:

1. **`flake.nix`** — just before launching QEMU, the runner `sqlite3 .backup`s the host's
   `/nix/var/nix/db/db.sqlite` to `$AGENT_DIR/.microvm-nix-db.sqlite`, riding in on the existing
   `agent-home` virtiofs share rather than a new mount. `.backup` rather than `cp` so the
   snapshot is consistent under concurrent host writes.
2. **`modules/base.nix`** — `microvm-import-nix-db.service`, a oneshot that installs that
   snapshot over `/nix/var/nix/db/db.sqlite`, ordered `Before=nix-daemon.service` and pulled in
   by `WantedBy=nix-daemon.service`.
3. **`modules/base.nix`** — `nix.gc.automatic = false`. Once the DB knows about host paths, GC
   would try to delete the ones without GC roots, and on overlayfs that means whiteouts in the
   upperdir hiding host paths. The writable layer starts empty on every boot anyway, so per-boot
   GC has no value.
4. **`modules/base.nix`** — `NIX_REMOTE = "daemon"`, forcing the CLI through the daemon. Without
   it, a missing socket makes nix fall back to single-user mode and fail opaquely on
   `creating directory "/nix/var/nix/temproots": Permission denied`.

**Verified 2026-08-25** in a running VM: after the import, host lowerdir paths resolve as valid,
`nix-store --verify` passes clean against the imported DB (no schema drift — host and guest run
the same nixpkgs, nix 2.34.8), and all three of `microvm-import-nix-db`, `nix-daemon.service` and
`nix-daemon.socket` come up active. The DB went from 339,968 bytes at boot to 101,810,176 bytes
holding 42,952 valid paths.

### The import runs lazily — don't panic at a small DB

Because the unit is `WantedBy=nix-daemon.service` and the daemon is socket-activated, the import
does not happen at boot. Until the first thing talks to the daemon, `/nix/var/nix/db/db.sqlite`
is still the boot-fresh ~332 KiB file, and it looks like the import silently failed. It didn't —
run any nix command and check again:

```sh
ls -l /nix/var/nix/db/db.sqlite      # ~332 KiB, boot mtime
nix path-info /nix/store/<some-host-path> >/dev/null
ls -l /nix/var/nix/db/db.sqlite      # ~97 MiB, mtime = just now
nix path-info --all | wc -l          # tens of thousands
```

`journalctl -u microvm-import-nix-db` would say so directly, but the guest user isn't in `adm`
or `systemd-journal`, so it only shows its own messages. Check the DB size instead.

### Two traps in the implementation

Both are load-bearing; the code carries comments saying so.

- **The unit ordering is deliberately narrow.** An earlier version also declared
  `Before=nix-daemon.socket`/`multi-user.target` with `WantedBy=multi-user.target`. That's a
  cycle: `sockets.target` wants `nix-daemon.socket`, which would wait on a unit wanted by
  `multi-user.target`, which activates after `sockets.target`. systemd broke it by **dropping
  `nix-daemon.socket`** — the socket was never created, the daemon never started, and nix fell
  back to single-user mode and died on `temproots`. Only order against `nix-daemon.service`.
- **`.backup` alone can spin forever.** SQLite restarts the backup from page 1 whenever another
  connection writes the source mid-copy, so on a host with an active `nix-daemon` it can loop
  without progressing. The runner opens an explicit read transaction on the same connection
  first, pinning a snapshot so external commits no longer invalidate copied pages. See the
  [SQLite forum thread](https://sqlite.org/forum/info/cca839708d74a20014f7188b86a19b267602d497bfa90ec1d1e79111a5b24adb).

### Residual risks

- **The snapshot is taken at launch and never refreshed.** Anything the host builds *after* the
  VM starts is absent from the guest DB and will be substituted. Relaunch to pick it up.
- **Manual GC is now more dangerous, not less.** `nix.gc.automatic = false` covers the timer, but
  a human running `nix-collect-garbage` will now have the DB agree that host paths are deletable,
  and produce exactly the whiteout storm the fix exists to avoid. Don't run it in the VM; only
  paths built inside the VM (real files in `/nix/.rw-store/store`) are reclaimable anyway. That
  subset is what `vm-store-prune` deletes — see below.
- **The snapshot costs ~97 MiB on the `agent-home` share** per launch, and grows with the host's
  store. Worth watching if that share is ever space-constrained.
- **Schema drift is possible in principle.** Host and guest take nix from the same nixpkgs input,
  so they agree today. If the host's nix ever outruns the guest's, importing a newer DB schema
  could break it; `nix-store --verify` with a fallback to the fresh DB would be the cheap defence.

## Where the writable store lives

`microvm.writableStoreOverlay = "/nix/.rw-store"` is the upper layer of that overlay: everything
the VM writes to `/nix/store` is a real file there. It is backed by a **sparse ext4 volume on the
host** (`$AGENT_HOME-store/nix-store-overlay.img`, 10 GiB by default), not by the RAM-backed
rootfs, because of how much lands in it:

- Every `nix develop` against a **dirty git worktree** snapshots the whole working directory into
  the store as a `…-source` path — Nix cannot use the git object store as the source when the tree
  is dirty — and mints a new one per distinct dirty state. Hundreds of MiB each is normal, and
  pre-commit hooks that shell out to `nix develop` mint one per commit.
- Anything substituted or built inside the VM, including the copy-ups described above.

On tmpfs a working day of that fills RAM and the VM starts failing writes with ENOSPC mid-commit.
On the volume it costs host disk. `modules/base.nix` also points the daemon's `TMPDIR` at the same
volume, so a large build unpacks there rather than into `/tmp` on the rootfs.

The image is recreated empty on every launch (`flake.nix`, in the runner script). A persistent one
would fight the DB import: the imported DB is the *host's*, so paths a previous run built are
present on disk but invalid according to nix, which then rebuilds them and never reclaims the
originals. Restarting the VM stays the guaranteed way back to an empty writable store.

### Reclaiming space without a restart

The guest ships `vm-store-prune` (`scripts/vm-store-prune.sh`):

```sh
vm-store-prune              # the `…-source` worktree snapshots, which are the bulk
vm-store-prune --all        # every VM-local path nothing references
vm-store-prune --dry-run    # list candidates, delete nothing
```

It offers only paths that exist in `/nix/.rw-store/store` **and not** in `/nix/.ro-store`, then
hands them to `nix store delete`, which refuses live paths rather than forcing them. Both halves
of that rule matter:

- A path present in *both* layers is a copy-up of a host path. Deleting it frees space but leaves
  a whiteout over a store path the DB still calls valid — the `nix-collect-garbage` failure mode
  by a smaller route. Anything hand-rolled from `ls -d /nix/store/*-source` walks straight into
  this, because that glob lists the merged view: host paths included.
- "Still alive" is not a failure. A dev shell you are inside, or a `result*` symlink in a repo,
  pins its snapshot until you leave or remove it. The remainder clears on the next restart.

### The disk does not make GC safe

Putting the writable layer on a disk changes *where* a GC's whiteouts land, and nothing else. The
lower layer is still the host's store over 9p, so `nix-collect-garbage` still walks the tens of
thousands of host paths the imported DB calls valid, still finds them unrooted, and still hides
each one behind a whiteout in the writable layer. What it costs is now disk rather than RAM; what
it breaks — `/nix/store` losing the host's paths mid-session, while the DB insists they are
valid — is exactly as bad as before. The bigger store just makes the temptation stronger.

`nix.settings.min-free` deserves a specific mention, because it is the version of this that nobody
chooses: set it, and nix runs the same GC on its own whenever a build sees the store filesystem
below the threshold. It is 0 (disabled) by default and `tests/store-overlay-disk.nix` pins it
there. `vm-store-prune` is the substitute — the same operation, scoped to paths that exist only in
the writable layer.

### Automatic pruning

`claude-vm.store.autoPrune` is what `min-free` would have been if it called the right collector: a
timer checks free space and runs `vm-store-prune` below the watermark (2 GiB by default). The
guardrails are the point, so they are worth stating:

| concern | how it is handled |
|---|---|
| cost of a tick when nothing is wrong | one `statfs`, then exit — the common path does no store walk |
| two runs overlapping | `Type=oneshot`, and the timer is `OnUnitInactiveSec` (interval measured from the last *finish*), so a slow run delays the next tick rather than queueing one behind it |
| a burst of catch-up runs | no `OnCalendar`, so nothing to be `Persistent` about after a suspend |
| a store pinned by a live dev shell | passes that free < 64 MiB are counted as ineffective and back off 15m → 30m → 1h → 2h; the counter resets the moment free space is healthy |
| competing with the agent's work | `Nice=19`, `IOSchedulingClass=idle`; deletion is I/O-bound, so that is the class that matters |
| a wedged run | `TimeoutStartSec=30min`; deletion happens path-by-path in the daemon, so a killed run is safe and the next tick continues |
| stale state after a restart | state lives in `/run`, which is cleared on boot — as is the writable store itself |
| a corrupt or hand-edited state file | non-numeric contents are discarded and treated as a fresh start |

It deliberately runs the default scope, not `--all`: the `…-source` snapshots are the growth it
exists to absorb, and deleting those surprises nobody. Unreferenced build outputs stay the user's
call. The watermark sits well above zero because pruning has to write to the nix database — the
time to act is before the store is full, not after.

`/run/vm-store-autoprune/status` carries the last outcome in one line; the guest user is in
neither `adm` nor `systemd-journal`, so it cannot read the unit's journal.

## Evaluating this flake inside the VM may fail

Unrelated to the DB, but it costs the same afternoon: the microvm.nix input's store path can
vanish from under a running VM (`does not exist`, while nix still considers it valid), and
`builtins.getFlake "/work"` trips over the `claude-vm.sock` socket in the repo root. Evaluate on
the host instead.
