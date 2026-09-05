# Reclaim space in the guest's writable /nix/store overlay.
#
# Ships *inside* the microVM (wired up in modules/base.nix); this is not a
# host-side tool. `set -euo pipefail` comes from writeShellApplication.
#
# Why not `nix-collect-garbage`: /nix/store in the guest is an overlay whose
# lower layer is the host's store, read-only over 9p, and whose upper layer is
# this VM's own writes. GC walks every path the nix DB knows about — which,
# after the host DB snapshot is imported at boot, means the host's entire store
# — and for each one it wants to delete it writes a whiteout into the upper
# layer. That burns the space it was meant to reclaim and hides host paths from
# /nix/store, breaking nix for the rest of the session.
#
# So this only ever offers paths that exist in the upper layer and NOT in the
# lower one: paths this VM created. A path present in both is a copy-up of a
# host path, and deleting it would leave a whiteout over a store path the DB
# still calls valid — the same breakage by a smaller route.
#
# Deletion is `nix store delete`, which refuses live paths ("still alive")
# instead of forcing them, so a dev shell you are still inside is never pulled
# out from under you.

rw=/nix/.rw-store/store
ro=/nix/.ro-store
all=0
dry=0

usage() {
  cat <<'EOF'
usage: vm-store-prune [-a|--all] [-n|--dry-run]

Deletes VM-local paths from /nix/store. By default only the `…-source`
snapshots that `nix develop` takes of a dirty git worktree, which are the
bulk of the growth; --all considers every path this VM created. Paths that
are still referenced are skipped, so this is safe to run at any time.

  -a, --all      consider every VM-local store path, not just `…-source`
  -n, --dry-run  list what would be offered for deletion, then stop
  -h, --help     show this text
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -a|--all) all=1 ;;
    -n|--dry-run) dry=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "vm-store-prune: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ ! -d "$rw" ]; then
  echo "vm-store-prune: $rw does not exist — this is not a claude-microvm guest" >&2
  exit 1
fi

# Everything the VM wrote that the host store does not already have.
candidates() {
  local p n
  for p in "$rw"/*; do
    n=${p##*/}
    # An unmatched glob (empty upper layer), and nix's own bookkeeping entries.
    case "$n" in
      '*'|.*|*.lock|trash) continue ;;
    esac
    if [ "$all" -eq 0 ]; then
      case "$n" in
        *-source) ;;
        *) continue ;;
      esac
    fi
    # Also in the lower layer: a copy-up of a host path. Deleting it whiteouts
    # the host's copy, which is exactly what must not happen.
    if [ -e "$ro/$n" ]; then
      continue
    fi
    printf '%s\n' "/nix/store/$n"
  done
}

usage_report() {
  df -h /nix/store / | sed 's/^/  /'
}

echo "before:"
usage_report

if [ "$dry" -eq 1 ]; then
  candidates
  exit 0
fi

# Repeat while a pass still shrinks the candidate set: deleting a snapshot can
# make the paths it referenced collectable in turn, and a batch that hits a live
# path stops early, leaving the rest of that batch for the next pass. Capped so
# a pathological case cannot spin.
prev=-1
pass=0
while [ "$pass" -lt 10 ]; do
  pass=$((pass + 1))
  mapfile -t paths < <(candidates)
  count=${#paths[@]}
  if [ "$count" -eq 0 ] || [ "$count" -eq "$prev" ]; then
    break
  fi
  prev=$count
  echo "pass $pass: $count path(s) to try"
  # Batched rather than one big argv: a single call over hundreds of paths is
  # one long-running operation with no visible progress. `nix store delete`
  # exits non-zero on a live path, which is expected, not a failure of the run.
  printf '%s\n' "${paths[@]}" | xargs -r -n 10 nix store delete 2>&1 \
    | grep -vE '^(finding garbage collector roots|removing stale temporary roots)' || true
done

echo "after:"
usage_report

remaining=$(candidates | wc -l)
if [ "$remaining" -gt 0 ]; then
  echo
  echo "$remaining VM-local path(s) could not be deleted. Usually one of:"
  echo "  * a dev shell you are still inside — exit it and run this again"
  echo "  * a gcroot: build outputs are 'result*' symlinks in your repos"
  echo "      nix-store --query --roots /nix/store/<path>"
  echo "  * a build still running"
  echo "The rest clears on the next VM restart: the writable store starts empty."
fi
