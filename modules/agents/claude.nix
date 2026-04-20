{ pkgs, ... }:
{
  claude-vm.agent = {
    name = "claude";
    launchCommand = "claude";
    extraPackages = [ pkgs.claude-code ];
    shellInit = ''
      # Seed microVM disk-space awareness into Claude's user-level memory
      mkdir -p ~/.claude
      if ! grep -q '<!-- MICROVM-DISK-SPACE -->' ~/.claude/CLAUDE.md 2>/dev/null; then
        cat >> ~/.claude/CLAUDE.md << 'VMEOF'

<!-- MICROVM-DISK-SPACE -->
# MicroVM Disk Space

You are running inside a microVM with a RAM-backed writable filesystem.
Disk space is severely limited. **Check disk space proactively** before
operations that consume storage (installing packages, building projects,
downloading files, writing large outputs).

## How to check

```bash
df -h / /nix
```

## Thresholds

- **Low space (<10% free)**: Warn the user immediately. Suggest cleanup:
  `rm -rf /tmp/*` and check for large files in the overlay upper layer with
  `du -sh /nix/.rw-store/store`
- **No space left (0% free or write failures like "No space left on device")**:
  Stop what you are doing and tell the user. Prioritise freeing space before
  continuing any other work. Clear `/tmp`, and verify space was reclaimed
  with `df -h`.

## IMPORTANT: Do NOT run `nix-collect-garbage`

`/nix/store` is an overlayfs over the host's read-only store. Running
`nix-collect-garbage` does NOT free space — it creates whiteout entries in
the RAM-backed upper layer for every host store path, which:
- wastes time (tens of thousands of paths)
- can fill up the tmpfs with whiteouts
- breaks Nix by hiding host store paths

To free Nix-related space, only remove paths that were built/installed
**inside the VM** (they live in `/nix/.rw-store/store` as real files,
not whiteouts).

Keep this in mind throughout the entire session.
VMEOF
      fi
    '';
  };

  environment.variables.DISABLE_AUTOUPDATER = "1";
}
