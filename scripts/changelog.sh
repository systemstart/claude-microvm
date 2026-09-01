#!/usr/bin/env bash
# Generate release notes from Conventional Commit subjects.
#
#   scripts/changelog.sh [<range>]
#
# <range> defaults to "<latest tag>..HEAD". Markdown goes to stdout; `make
# release-tag` uses it as the annotated tag body, which the release workflow
# copies into the GitHub release.
#
# Every commit lands in some section — unrecognised types and subjects that are
# not Conventional Commits fall through to "Other" rather than being dropped, so
# the notes can never silently omit a change.
set -euo pipefail

range="${1:-}"
if [ -z "$range" ]; then
  prev="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  range="${prev:+$prev..}HEAD"
fi

breaking=() security=() feats=() fixes=() docs=() other=()

# Records are \x1e-separated and fields \x1f-separated: commit bodies are
# multi-line, so a plain line-oriented read would split them across records.
while IFS= read -r -d $'\x1e' record; do
  record="${record#$'\n'}"
  hash="${record%%$'\x1f'*}"; rest="${record#*$'\x1f'}"
  subject="${rest%%$'\x1f'*}"; body="${rest#*$'\x1f'}"
  [ -n "$hash" ] || continue

  type="" scope="" bang="" desc="$subject"
  if [[ "$subject" =~ ^([a-zA-Z]+)(\(([^\)]*)\))?(!)?:[[:space:]]*(.*)$ ]]; then
    type="${BASH_REMATCH[1],,}"
    scope="${BASH_REMATCH[3]}"
    bang="${BASH_REMATCH[4]}"
    desc="${BASH_REMATCH[5]}"
  fi

  entry="* ${scope:+**$scope**: }$desc (\`$hash\`)"

  if [ -n "$bang" ] || [[ "$body" == *"BREAKING CHANGE"* ]]; then
    breaking+=("$entry")
  else
    case "$type" in
      harden|sec|security)
                  security+=("$entry") ;;
      feat)       feats+=("$entry") ;;
      fix)        fixes+=("$entry") ;;
      docs)       docs+=("$entry")  ;;
      *)          other+=("$entry") ;;
    esac
  fi
done < <(git log --no-merges --reverse --format="%h%x1f%s%x1f%b%x1e" "$range")

section() {
  local title="$1"; shift
  [ "$#" -gt 0 ] || return 0
  printf '### %s\n\n' "$title"
  printf '%s\n' "$@"
  printf '\n'
}

section "Breaking changes" ${breaking+"${breaking[@]}"}
section "Security"         ${security+"${security[@]}"}
section "Features"         ${feats+"${feats[@]}"}
section "Fixes"            ${fixes+"${fixes[@]}"}
section "Documentation"    ${docs+"${docs[@]}"}
section "Other"            ${other+"${other[@]}"}
