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

The rootfs is a RAM-backed tmpfs of a few GiB, so a fetch of that size is roughly enough to fill
the disk and brick the VM.

### Cause

`/nix/store` is an overlay — the host's store read-only via virtio-9p as the lowerdir, a
tmpfs-backed upperdir for anything the VM writes:

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
overlayfs **copy the path up into the tmpfs upperdir**, even though byte-identical content
already exists in the lowerdir.

Every "fetch" therefore charges the tmpfs rootfs for the unpacked size of a path that was already
on disk.

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
   tmpfs upperdir hiding host paths. The rootfs is tmpfs anyway, so per-boot GC has no value.
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
  paths built inside the VM (real files in `/nix/.rw-store/store`) are reclaimable anyway.
- **The snapshot costs ~97 MiB on the `agent-home` share** per launch, and grows with the host's
  store. Worth watching if that share is ever space-constrained.
- **Schema drift is possible in principle.** Host and guest take nix from the same nixpkgs input,
  so they agree today. If the host's nix ever outruns the guest's, importing a newer DB schema
  could break it; `nix-store --verify` with a fallback to the fresh DB would be the cheap defence.

## Evaluating this flake inside the VM may fail

Unrelated to the DB, but it costs the same afternoon: the microvm.nix input's store path can
vanish from under a running VM (`does not exist`, while nix still considers it valid), and
`builtins.getFlake "/work"` trips over the `claude-vm.sock` socket in the repo root. Evaluate on
the host instead.
