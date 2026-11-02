# Read one key from the launcher's .microvm-env as data, never as code.
#
#   microvm-env-get <env-file> <KEY>
#
# Prints the value of the last `KEY=` line, or nothing when the file or the key
# is absent. `set -euo pipefail` comes from writeShellApplication.
#
# The guest's root services (cri-proxy-env, cri-activate in modules/cri.nix)
# need a few keys from this file. It reaches the guest on the read-only
# instance share (options.claude-vm.instance in modules/base.nix), but a root
# service still has no business executing it: sourcing would run whatever the
# file says, so a launcher bug or a value that escaped its quoting would run as
# root. So nothing here evaluates the file: no expansion, no command
# substitution, no word splitting.
#
# Last match wins, as it does when the agent's login shell sources the file:
# EXTRA_ENV is written after everything else so that it can override a key.
# microvm-policy's services read their own keys from this file the same way.
#
# The launcher writes some values plainly and some with printf %q. For
# printable text %q only ever backslash-escapes — `a,b` becomes `a\,b` — and
# writes an empty value as `''`, so this undoes exactly those two forms and
# gets what sourcing would have assigned. Anything else (`$'…'`, which %q uses
# only for control characters, or quotes the launcher never writes) comes back
# as plain text, for the caller's own validation to turn away.

env_file="${1:?usage: microvm-env-get <env-file> <KEY>}"
key="${2:?usage: microvm-env-get <env-file> <KEY>}"

if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "microvm-env-get: not a variable name: '$key'" >&2
  exit 2
fi

[ -f "$env_file" ] || exit 0

raw=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "$key="*) raw="${line#"$key="}" ;;
  esac
done < "$env_file"

[ "$raw" = "''" ] && raw=""

# \X is X; a trailing lone backslash is dropped, as the shell would.
value=""
while [[ "$raw" == *\\* ]]; do
  value+="${raw%%\\*}"
  raw="${raw#*\\}"
  value+="${raw:0:1}"
  raw="${raw:1}"
done
value+="$raw"

printf '%s\n' "$value"
