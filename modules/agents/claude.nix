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
  `sudo nix-collect-garbage -d` and `rm -rf /tmp/*`
- **No space left (0% free or write failures like "No space left on device")**:
  Stop what you are doing and tell the user. Prioritise freeing space before
  continuing any other work. Run `sudo nix-collect-garbage -d`, clear `/tmp`,
  and verify space was reclaimed with `df -h`.

Keep this in mind throughout the entire session.
VMEOF
      fi
    '';
  };

  environment.variables.DISABLE_AUTOUPDATER = "1";
}
