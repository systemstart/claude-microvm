{ pkgs, ... }:
{
  claude-vm.agent = {
    name = "claude";
    launchCommand = "claude";
    extraPackages = [ pkgs.claude-code ];
    shellInit = ''
      # Seed microVM disk-space awareness into Claude's user-level memory. This
      # runs inside base.nix's seed lock (it inlines shellInit there), so it
      # needs no locking of its own.
      mkdir -p ~/.claude
      # Supersedes the pre-store-volume block, which told the agent that the
      # writable store lives in RAM and that clearing /tmp is the remedy.
      if grep -q '<!-- MICROVM-DISK-SPACE -->' ~/.claude/CLAUDE.md 2>/dev/null; then
        sed -i '/<!-- MICROVM-DISK-SPACE -->/,/^Keep this in mind throughout the entire session\.$/d' ~/.claude/CLAUDE.md
      fi
      if ! grep -q '<!-- MICROVM-DISK-SPACE-2 -->' ~/.claude/CLAUDE.md 2>/dev/null; then
        cat >> ~/.claude/CLAUDE.md << 'VMEOF'

<!-- MICROVM-DISK-SPACE-2 -->
# MicroVM Disk Space

Two filesystems here can fill up, for different reasons. **Check before
operations that consume storage** (installing packages, building projects,
downloading files, writing large outputs):

```bash
df -h / /nix/store
```

- **`/` is a RAM-backed tmpfs** of a few GiB with no slack — what fills it is
  memory. `/tmp` and anything written outside `/work` and `/home/agent` counts
  against it.
- **`/nix/store` is an overlay**: the host's store read-only underneath, plus
  this VM's writes on a dedicated sparse disk. Every `nix build`, `nix develop`
  and substitution lands there — including a full copy of the working tree each
  time a flake input is a dirty git worktree, which is hundreds of MiB per
  distinct dirty state.
- `/work` and `/home/agent` are host directories over virtiofs, and
  `/var/lib/containers` is its own disk. Files there cost neither of the above.

## Thresholds

- **Low space (<10% free)**: warn the user immediately, and say *which* of the
  two is filling — the remedies are different.
- **No space left** (`No space left on device`): stop and tell the user before
  continuing anything else.

## Reclaiming space in /nix/store

```bash
vm-store-prune              # drop the `…-source` worktree snapshots
vm-store-prune --all        # every VM-local path nothing references
vm-store-prune --dry-run    # list first, delete nothing
```

It skips paths that are still referenced, so it is safe to run at any time.
Batching work into fewer `nix develop` / commit cycles is what stops the
snapshots accumulating in the first place.

A timer already runs the first of those when free space drops below 2 GiB, and
backs off if a pass frees nothing — so if the store is tight, something live is
holding it (a dev shell you are still in, a `result` symlink, a running build)
rather than nobody having cleaned up. `cat /run/vm-store-autoprune/status` shows
the last outcome.

## IMPORTANT: Do NOT run `nix-collect-garbage`

It does not free space here and it breaks Nix. `/nix/store` is an overlay over
the host's read-only store, so GC writes a whiteout into this VM's writable
layer for every host path it wants to delete: it consumes the space it was
meant to reclaim, takes minutes, and hides host store paths from `/nix/store`.
The same goes for anything that shells out to a full GC (`nix store gc`,
`nix-store --gc`). Use `vm-store-prune`, which only ever touches paths this VM
created.

Keep this in mind throughout the entire session.
VMEOF
      fi
    '';
  };

  environment.variables.DISABLE_AUTOUPDATER = "1";
}
