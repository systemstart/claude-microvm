#!/usr/bin/env bash
# Bump modules/agents/claude-code-manifest.json to a newer Claude Code release.
#
#   scripts/update-claude-code.sh [latest|stable|<version>]
#
# nixpkgs' claude-code derivation takes everything it needs (version and
# per-platform checksums) from Anthropic's release manifest, so an update is
# just a new copy of that file. It is only accepted if:
#
#   * it carries a valid signature from Anthropic's release key. The key is
#     committed next to this script and pinned by fingerprint below, so a
#     compromised CDN cannot hand us a different one;
#   * its own "version" field is the version we asked for. The signature covers
#     the file, not the URL it came from, so this stops an older signed
#     manifest from being served in place of the new one;
#   * it is strictly newer than what we already have. No downgrades.
#
# The file is copied byte for byte, so anyone can re-check it later with
# `gpg --verify` against the upstream .sig.
set -euo pipefail

BASE_URL="https://downloads.claude.ai/claude-code-releases"
KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/modules/agents/claude-code-manifest.json"
keyfile="$root/scripts/claude-code-release-key.asc"

die() { echo "error: $*" >&2; exit 1; }

target="${1:-latest}"
case "$target" in
  latest|stable) version="$(curl -fsSL "$BASE_URL/$target")" ;;
  *) version="$target" ;;
esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected version string '$version'"

current="$(jq -r .version "$manifest")"
if [ "$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -n1)" = "$current" ]; then
  echo "claude-code is up to date ($current, upstream $target is $version)"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GNUPGHOME="$tmp/gnupg"
mkdir -m 700 "$GNUPGHOME"

gpg --batch --quiet --import "$keyfile"
gpg --batch --with-colons --fingerprint | grep -qx "fpr:::::::::$KEY_FPR:" \
  || die "$keyfile does not hold the release key $KEY_FPR"

curl -fsSL "$BASE_URL/$version/manifest.zst.json" -o "$tmp/manifest.json"
curl -fsSL "$BASE_URL/$version/manifest.zst.json.sig" -o "$tmp/manifest.json.sig"

# Go by gpg's machine-readable status rather than its exit code, and require
# the signature to chain to the pinned key specifically: VALIDSIG carries the
# signing key's fingerprint first and the primary key's last.
status="$(gpg --batch --status-fd 1 --verify "$tmp/manifest.json.sig" "$tmp/manifest.json" 2>/dev/null || true)"
awk -v fpr="$KEY_FPR" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && ($3 == fpr || $NF == fpr) { ok = 1 } END { exit !ok }' <<<"$status" \
  || die "no valid signature from $KEY_FPR on the $version manifest"

got="$(jq -r .version "$tmp/manifest.json")"
[ "$got" = "$version" ] || die "asked for $version, the signed manifest says $got"

for platform in linux-x64 linux-arm64; do
  jq -e --arg p "$platform" '.platforms[$p].checksum | test("^[0-9a-f]{64}$")' "$tmp/manifest.json" >/dev/null \
    || die "the $version manifest has no checksum for $platform"
done

cp "$tmp/manifest.json" "$manifest"
echo "claude-code: $current -> $version"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "previous=$current" >> "$GITHUB_OUTPUT"
  echo "version=$version" >> "$GITHUB_OUTPUT"
fi
