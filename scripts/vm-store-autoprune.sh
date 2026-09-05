# Watermark-driven wrapper around vm-store-prune, run by a systemd timer in the
# guest (modules/base.nix). `set -euo pipefail` comes from writeShellApplication.
#
# This is deliberately NOT nix's own `min-free`. That setting hooks the build
# loop and calls the full garbage collector, which on this overlay walks the
# host's store through the lower layer and whiteouts it — see
# docs/NIX-STORE-GOTCHAS.md. Same trigger, wrong collector. Out-of-band timer
# plus a collector scoped to the writable layer is the version that is safe.
#
# The design constraint is that this must never become a load source of its own,
# least of all while the VM is under pressure:
#
#   * A tick that finds space is one statfs and exits — the common case costs
#     nothing.
#   * The timer is OnUnitInactiveSec, so the next tick is measured from when the
#     last run *finished*. Runs cannot overlap, and a slow run cannot build a
#     backlog of queued ones the way OnCalendar would.
#   * A pass that frees nothing means the space is held by something live (a dev
#     shell, a gcroot, a running build) and running again immediately would
#     re-walk the whole store to delete nothing. Consecutive ineffective passes
#     back off 15m → 30m → 1h → 2h, and the backoff resets the moment free space
#     is healthy again.
#
# State lives in /run (tmpfs, cleared on boot), which is the correct lifetime:
# the writable store starts empty on every launch, so backoff earned by a
# previous session means nothing to this one.

STATE_DIR=/run/vm-store-autoprune
STATE="$STATE_DIR/state"
STATUS="$STATE_DIR/status"

# A pass freeing less than this is treated as ineffective for backoff purposes:
# below it we are paying a full store walk for noise.
MIN_FREED_MIB=64

# Cooldown after N consecutive ineffective passes, in seconds. The first entry
# is "no cooldown": one ineffective pass is not evidence of a stuck store, and
# space may free up on its own when a shell exits.
COOLDOWNS=(0 900 1800 3600 7200)

threshold=${VM_STORE_PRUNE_FREE_MIB:?VM_STORE_PRUNE_FREE_MIB must be set}

avail_mib() {
  # statfs of the overlay reports the writable layer's filesystem, which is what
  # actually runs out — the read-only host store underneath cannot fill.
  df -BM --output=avail /nix/store | tail -n1 | tr -dc '0-9'
}

say() {
  # Journal for history, and a world-readable file for the agent: the guest user
  # is in neither `adm` nor `systemd-journal`, so it cannot read its own logs.
  echo "$1"
  printf '%s\n' "$1" > "$STATUS"
}

mkdir -p "$STATE_DIR"

now=$(date +%s)
free_now=$(avail_mib)

if [ "$free_now" -ge "$threshold" ]; then
  # Healthy: clear any backoff earned earlier so the next shortage is handled
  # promptly rather than sitting out a stale cooldown.
  echo "0 0" > "$STATE"
  say "$(date -Is) ok: ${free_now}MiB free in /nix/store (threshold ${threshold}MiB)"
  exit 0
fi

cooldown_until=0
strikes=0
if [ -r "$STATE" ]; then
  read -r cooldown_until strikes < "$STATE" || true
  # A truncated or hand-edited state file must not wedge the timer.
  case "$cooldown_until$strikes" in
    *[!0-9]*|'') cooldown_until=0; strikes=0 ;;
  esac
fi

if [ "$now" -lt "$cooldown_until" ]; then
  say "$(date -Is) low: ${free_now}MiB free, holding off for $((cooldown_until - now))s (${strikes} ineffective pass(es))"
  exit 0
fi

echo "$(date -Is) low: ${free_now}MiB free (threshold ${threshold}MiB), pruning"
# Default scope, not --all: the `…-source` worktree snapshots are the growth
# this exists to absorb, and deleting them surprises nobody. Unreferenced build
# outputs are the user's call — `vm-store-prune --all` by hand.
vm-store-prune || true

free_after=$(avail_mib)
freed=$((free_after - free_now))

if [ "$freed" -ge "$MIN_FREED_MIB" ]; then
  strikes=0
else
  strikes=$((strikes + 1))
fi

idx=$strikes
[ "$idx" -lt "${#COOLDOWNS[@]}" ] || idx=$(( ${#COOLDOWNS[@]} - 1 ))
cooldown=${COOLDOWNS[$idx]}
echo "$((now + cooldown)) $strikes" > "$STATE"

say "$(date -Is) pruned: ${freed}MiB freed, ${free_after}MiB free$( [ "$cooldown" -gt 0 ] && echo ", next attempt in $((cooldown / 60))min" )"
