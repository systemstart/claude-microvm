# Recover a virtiofs share that has wedged with ENFILE.
#
# Ships inside the microVM (modules/base.nix); needs root, so it re-execs itself
# through the one sudo rule that allows it. `set -euo pipefail` comes from
# writeShellApplication.
#
# The failure it fixes: the host's virtiofsd holds one O_PATH file descriptor
# per inode this guest has looked up, and releases it only when the guest evicts
# the dentry and sends FUSE FORGET. A large tree walk — an unbounded `find`, a
# test run over a big module tree, anything that stats millions of files — can
# push the daemon into its file descriptor ceiling (typically 524288, the host
# systemd hard limit). After that *every* operation on the share fails with
# ENFILE, while every counter inside the guest looks perfectly healthy, because
# the exhaustion is on the other side of the mount.
#
# It does not clear by itself: no memory pressure in the guest means no dentry
# eviction, which means no FORGETs, which means the host never gets its
# descriptors back. Retrying makes it worse, since each retry is more lookups.
#
# Dropping the guest's dentry and inode caches forces those FORGETs immediately.
# The cost is a cold cache — paths get looked up again on next use — which is
# cheap next to a VM restart, the only other way out.
#
# Neither of the fixes suggested for this upstream applies to how this VM runs
# its shares; see docs/VIRTIOFS-GOTCHAS.md before adding flags to the launcher.

if [ "$(id -u)" -ne 0 ]; then
  # The sudo rule in modules/base.nix names this exact path.
  exec sudo -n /run/current-system/sw/bin/vm-share-relieve "$@"
fi

dentries() { awk '{print $1}' /proc/sys/fs/dentry-state; }

before=$(dentries)

# Flush dirty pages first: drop_caches only frees clean entries, so without this
# the writes you are about to lose the cache for stay pinned anyway.
sync
# 2 = dentries and inodes. Not 3: the page cache is not what holds the host's
# descriptors, and dropping it would just make everything slow for no gain.
echo 2 > /proc/sys/vm/drop_caches

after=$(dentries)

echo "vm-share-relieve: dentries $before -> $after ($((before - after)) released)"
echo "The host daemon reclaims its file descriptors as the FORGET messages arrive."
echo "If the share is still wedged, something in the guest is walking it faster"
echo "than this frees it — stop that first, then run this again."
