# Point the guest's container runtimes at registry mirrors (REGISTRY_MIRRORS).
#
# Runs as root at boot from cri-registry-mirrors.service (modules/cri.nix),
# before any container daemon starts. `set -euo pipefail` comes from
# writeShellApplication.
#
#   registry-mirrors <env-file> <root>
#
# <env-file> is the launcher's .microvm-env; <root> is "/" in the guest and a
# scratch directory in tests/registry-mirrors.nix. REGISTRY_MIRRORS is a
# comma-separated list of <registry>=<url>, e.g.
#
#   docker.io=http://10.0.2.2:5101,ghcr.io=http://10.0.2.2:5102
#
# For each entry this writes what every runtime here reads:
#
#   containerd, both instances — so CRI and crictl pulls
#       <root>/etc/containerd/certs.d/<registry>/hosts.toml
#   podman and CRI-O
#       <root>/etc/containers/registries.conf.d/50-registry-mirrors.conf
#   docker — Hub only: dockerd has no mirror setting for any other registry
#       <root>/run/cri-registry-mirrors.env, as DOCKERD_MIRROR_ARGS
#
# Every runtime tries the mirror first and falls back to the registry itself
# when the mirror cannot be reached, so a mirror that is down costs nothing but
# the cache. The guest's /etc lives on its tmpfs root, so none of this outlives
# the boot.
#
# The launcher validates REGISTRY_MIRRORS before it touches the host, but the
# env file sits in the agent's home, which the guest can write — so entries are
# checked again here before any of them becomes a path or a config line.

env_file="${1:?usage: registry-mirrors <env-file> <root>}"
root="${2:?usage: registry-mirrors <env-file> <root>}"
root="${root%/}"

REGISTRY_MIRRORS=""
EGRESS_POLICY=""
# shellcheck disable=SC1090  # written by the launcher at every boot
[ -f "$env_file" ] && source "$env_file"

[ -n "$REGISTRY_MIRRORS" ] || exit 0

# A sealed network reaches only the egress proxy, and the daemons' NO_PROXY
# sends 10.0.2.0/24 direct — so a mirror there would be tried, dropped by the
# seal, and fallen back from on every pull. The proxy's allowlist already
# governs where pulls go; leave the runtimes pulling through it.
case "$EGRESS_POLICY" in
  shadow|enforce)
    echo "registry-mirrors: ignoring REGISTRY_MIRRORS under EGRESS_POLICY=$EGRESS_POLICY (the seal blocks them; pulls go through the proxy)" >&2
    exit 0 ;;
esac

entry_re='^[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?=https?://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/?$'

umask 022
conf="$root/etc/containers/registries.conf.d/50-registry-mirrors.conf"
mkdir -p "$(dirname "$conf")" "$root/run"
printf '# Written at boot by registry-mirrors from REGISTRY_MIRRORS.\n' > "$conf"
docker_args=""
written=""

IFS=',' read -ra entries <<< "$REGISTRY_MIRRORS"
for entry in "${entries[@]}"; do
  if ! [[ "$entry" =~ $entry_re ]]; then
    echo "registry-mirrors: skipping malformed entry '$entry' (want <registry>=http[s]://<host>[:<port>])" >&2
    continue
  fi
  registry="${entry%%=*}"
  url="${entry#*=}"
  url="${url%/}"
  scheme="${url%%://*}"
  hostport="${url#*://}"

  # Docker Hub's API is not served at docker.io itself.
  case "$registry" in
    docker.io) server="https://registry-1.docker.io" ;;
    *)         server="https://$registry" ;;
  esac

  # A <registry>:<port> name is a directory named with the colon, as
  # containerd's hosts-dir lookup expects.
  mkdir -p "$root/etc/containerd/certs.d/$registry"
  cat > "$root/etc/containerd/certs.d/$registry/hosts.toml" <<EOF
# Written at boot by registry-mirrors from REGISTRY_MIRRORS.
server = "$server"

[host."$url"]
  capabilities = ["pull", "resolve"]
EOF

  insecure=false
  [ "$scheme" = "http" ] && insecure=true
  cat >> "$conf" <<EOF

[[registry]]
prefix = "$registry"
location = "$registry"
[[registry.mirror]]
location = "$hostport"
insecure = $insecure
EOF

  [ "$registry" = "docker.io" ] && docker_args="--registry-mirror=$url"
  written="$written $registry"
done

printf 'DOCKERD_MIRROR_ARGS=%s\n' "$docker_args" > "$root/run/cri-registry-mirrors.env"

if [ -n "$written" ]; then
  echo "registry-mirrors: mirroring${written}"
else
  echo "registry-mirrors: no usable entries in REGISTRY_MIRRORS" >&2
fi
