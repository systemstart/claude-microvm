# Stop a running launch from outside the VM, the way pressing its power button
# would: the guest shuts down cleanly, QEMU exits, and the launcher cleans up
# as it does after any VM exit — daemons stopped, instance dir removed.
#
#   microvm-stop [--force] [--timeout <seconds>] [<id> | <instance dir>]
#
# Without an argument it stops the only running launch, and lists them if
# there is more than one. `set -euo pipefail` comes from writeShellApplication.
#
# A launch's instance dir is $XDG_RUNTIME_DIR/claude-microvm/vms/<id> (see
# "Instance dir" in flake.nix). Its QMP socket is always qmp.sock there — taken
# from the layout, not from instance.json, which only describes the launch and
# whose id must match the dir's name. Its lock, which the launcher and QEMU hold
# until both have gone, says whether it is still running. The power button is
# QMP's system_powerdown. --force sends QMP's quit instead: QEMU
# exits at once, with no shutdown in the guest — as `systemctl --user stop` on
# the launch's slice does, but working for launches without a scope too.
#
# Exit status: 0 stopped (or was not running), 1 not found or unreachable,
# 2 usage, 3 still running after the timeout.

usage() {
  echo "usage: microvm-stop [--force] [--timeout <seconds>] [<id> | <instance dir>]" >&2
  exit 2
}

force=0
timeout=60
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force=1 ;;
    --timeout) [ $# -ge 2 ] || usage; timeout="$2"; shift ;;
    --timeout=*) timeout="${1#--timeout=}" ;;
    -h|--help) usage ;;
    -*) echo "microvm-stop: unknown option: $1" >&2; usage ;;
    *) [ -z "$target" ] || usage; target="$1" ;;
  esac
  shift
done
[[ "$timeout" =~ ^[0-9]+$ ]] || { echo "microvm-stop: --timeout wants whole seconds, not '$timeout'" >&2; exit 2; }

vms="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/claude-microvm/vms"

# Whether a launch still holds its lock. The lock file is opened read-only
# and never created: a dir mid-removal must not get a new file put back in it.
running() { # instance dir
  local fd
  [ -e "$1/lock" ] || return 1
  # Braces: `exec` with only redirections keeps them, so a 2>/dev/null on it
  # would silence the rest of the script.
  { exec {fd}<"$1/lock"; } 2>/dev/null || return 1
  if flock -n "$fd"; then exec {fd}<&-; return 1; fi
  exec {fd}<&-
  return 0
}

live=()
if [ -d "$vms" ]; then
  for d in "$vms"/*/; do
    d="${d%/}"
    [ -f "$d/instance.json" ] && running "$d" && live+=("$d")
  done
fi

if [ -z "$target" ]; then
  case "${#live[@]}" in
    0) echo "microvm-stop: no running launches under $vms" >&2; exit 1 ;;
    1) dir="${live[0]}" ;;
    *)
      echo "microvm-stop: ${#live[@]} launches are running; name one:" >&2
      for d in "${live[@]}"; do
        printf '  %s  %s\n' "$(basename "$d")" "$(jq -r .work "$d/instance.json" 2>/dev/null)" >&2
      done
      exit 1 ;;
  esac
elif [ -d "$target" ] && [ -f "$target/instance.json" ]; then
  dir="${target%/}"
elif [[ "$target" =~ ^[0-9a-f]{12}$ ]]; then
  dir="$vms/$target"
  [ -f "$dir/instance.json" ] || { echo "microvm-stop: no launch $target under $vms" >&2; exit 1; }
else
  echo "microvm-stop: '$target' is neither a launch ID (12 hex digits) nor an instance dir" >&2
  exit 2
fi

# An instance.json edited by hand, or copied from another launch's dir, must
# not send us to the wrong VM: the ID is the dir's name, and the socket is
# where the layout puts it, whatever the file says.
id="$(basename "$dir")"
if [ "$(jq -r .id "$dir/instance.json" 2>/dev/null)" != "$id" ]; then
  echo "microvm-stop: $dir/instance.json is not this launch's (its id is not $id); not acting on it" >&2
  exit 1
fi
work="$(jq -r .work "$dir/instance.json")"
qmp="$dir/qmp.sock"

if ! running "$dir"; then
  echo "microvm-stop: $id is not running (its launcher has gone; $dir is left over)"
  exit 0
fi

if [ "$force" = 1 ]; then
  command='{"execute":"quit"}'
  echo "microvm-stop: stopping $id ($work) at once — QEMU exits without a shutdown in the guest"
else
  command='{"execute":"system_powerdown"}'
  echo "microvm-stop: powering off $id ($work)"
fi
# QMP wants qmp_capabilities before anything else. -t gives QEMU time to answer
# after our input ends; its replies are only for the error check.
if ! reply="$(printf '%s\n' '{"execute":"qmp_capabilities"}' "$command" \
               | socat -t 2 - "UNIX-CONNECT:$qmp" 2>&1)"; then
  echo "microvm-stop: cannot reach QEMU at $qmp: $reply" >&2
  exit 1
fi
if grep -q '"error"' <<< "$reply"; then
  echo "microvm-stop: QEMU refused: $(grep '"error"' <<< "$reply" | head -1)" >&2
  exit 1
fi

# The lock goes when the launcher exits, which is after its cleanup.
waited=0
while running "$dir"; do
  if [ "$waited" -ge "$timeout" ]; then
    echo "microvm-stop: $id is still running after ${timeout}s" >&2
    [ "$force" = 1 ] || echo "              the guest may be ignoring the power button; --force stops QEMU at once" >&2
    exit 3
  fi
  sleep 1
  waited=$((waited + 1))
done
echo "microvm-stop: $id stopped"
