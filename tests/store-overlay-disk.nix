# Eval-level pins for the writable /nix/store volume (modules/base.nix,
# `claude-vm.store`). Not a nixosTest: none of this needs a booted VM, and the
# things that break it are silent — a volume that stops being `neededForBoot`
# leaves the initrd mounting the overlay on an empty directory, and a size that
# collides with the CRI volume's makes the runner's `truncate -s <size>M`
# rewrite ambiguous. Both would still evaluate and boot, badly.
{ pkgs, lib, config }:

let
  overlay = config.microvm.writableStoreOverlay;
  volumes = config.microvm.volumes;
  storeVol = lib.findFirst (v: v.mountPoint == overlay) null volumes;
  criVol = lib.findFirst (v: v.mountPoint == "/var/lib/containers") null volumes;
  fs = config.fileSystems.${overlay} or null;
  daemonTmpdir = config.systemd.services.nix-daemon.environment.TMPDIR or null;
  autoPrune = config.claude-vm.store.autoPrune;
  autoPruneService = config.systemd.services.vm-store-autoprune or { };
  autoPruneTimer = config.systemd.timers.vm-store-autoprune or { };

  checks = [
    {
      name = "the writable store overlay is on a volume, not the tmpfs rootfs";
      ok = overlay != null && storeVol != null;
    }
    {
      name = "that volume is an ext4 disk (overlayfs needs a real upperdir fs)";
      ok = storeVol != null && storeVol.fsType == "ext4";
    }
    {
      name = "it is identified by label, so the volumes cannot swap drive letters";
      ok = storeVol != null && storeVol.label != null
        && fs != null && fs.device == "/dev/disk/by-label/${storeVol.label}";
    }
    {
      name = "it is mounted in the initrd, before the overlay that uses it";
      ok = fs != null && fs.neededForBoot;
    }
    {
      name = "its image name is the literal the runner rewrites";
      ok = storeVol != null && storeVol.image == "nix-store-overlay.img";
    }
    {
      name = "store and CRI volumes differ in image, label and default size";
      ok = criVol == null || (storeVol != null
        && storeVol.image != criVol.image
        && storeVol.label != criVol.label
        && storeVol.size != criVol.size);
    }
    {
      name = "nix build directories are on the volume, not on /tmp in RAM";
      ok = daemonTmpdir != null && lib.hasPrefix "${overlay}/" daemonTmpdir;
    }
    {
      name = "GC stays off — on this overlay it whiteouts host paths";
      ok = !config.nix.gc.automatic
        && !config.nix.settings.auto-optimise-store
        && !config.nix.optimise.automatic;
    }
    {
      # The two volumes need opposite treatment and it is easy to copy the wrong
      # one. `nofail` on the CRI mount is what makes CRI_STORAGE_SIZE=0 bootable;
      # `nofail` on the store mount would be a lie — the initrd requires it, and
      # the overlay above it would mount on an empty directory.
      name = "CRI mount tolerates a missing disk, the store mount does not";
      ok = (criVol == null || lib.elem "nofail" (config.fileSystems."/var/lib/containers".options or [ ]))
        && !(lib.elem "nofail" (fs.options or [ ]));
    }
    {
      name = "auto-prune is timer-driven, and only the timer starts it";
      ok = !autoPrune.enable || (
        autoPruneService.serviceConfig.Type or null == "oneshot"
        # Wanted by nothing: a stray target dependency would run a store walk at
        # boot, when the writable store is empty by construction.
        && autoPruneService.wantedBy == [ ]
        && autoPruneTimer.wantedBy == [ "timers.target" ]
      );
    }
    {
      # OnUnitInactiveSec measures from when the last run finished, so ticks can
      # neither overlap nor pile up. OnCalendar would do neither, and with
      # Persistent= it would fire a catch-up burst after a suspend.
      name = "auto-prune cannot overlap or accumulate a backlog";
      ok = !autoPrune.enable || (
        (autoPruneTimer.timerConfig.OnUnitInactiveSec or null) != null
        && (autoPruneTimer.timerConfig.OnCalendar or null) == null
      );
    }
    {
      # A watermark at or above the volume size can never be satisfied: every
      # tick would prune, find nothing, and back off — cleanup that never stops
      # asking. Well below it is the only sane range.
      name = "auto-prune watermark leaves room below the store cap";
      ok = !autoPrune.enable || !config.claude-vm.store.diskBacked
        || autoPrune.freeMiB * 2 < config.claude-vm.store.size;
    }
    {
      # The back door: `min-free` makes nix run a GC by itself whenever a build
      # finds the store filesystem below the threshold. Same GC, same whiteout
      # storm, minus the human deciding to run it — and a bigger store volume
      # makes "let nix clean up under pressure" look reasonable. 0 disables it,
      # which is both the nix default and the only correct value here.
      name = "disk-pressure GC stays off (min-free)";
      ok = (config.nix.settings.min-free or 0) == 0;
    }
  ];
in
pkgs.runCommand "store-overlay-disk" { } (''
  fail=0
'' + lib.concatMapStrings ({ name, ok }: ''
  if ${if ok then "true" else "false"}; then
    echo "ok: ${name}"
  else
    echo "FAIL: ${name}" >&2
    fail=1
  fi
'') checks + ''
  [ "$fail" -eq 0 ] || exit 1
  touch $out
'')
