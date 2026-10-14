#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Move this blueprint to a new client release.
#
#   scripts/bump.sh --show
#   scripts/bump.sh <new-config-file> <image>=<new-tag> [<image>=<new-tag> ...]
#
# Example:
#   scripts/bump.sh nitro-v3.13.0-full.yml offchainlabs/nitro-node=v3.13.0-1a2b3c4
#
# Renames the configuration file, repins the image tags, and rewrites every
# reference to the old file name and versions (package.json, samples, README,
# tests). Nothing is committed: review `git diff`, then run scripts/validate.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

die() { echo "error: $*" >&2; exit 1; }

configs=(configurations/*.yml)
[[ ${#configs[@]} -eq 1 && -f "${configs[0]}" ]] || die "expected exactly one file in configurations/"
old_config="$(basename "${configs[0]}")"

# Tag pinned for <image> in configurations/<file>.
pinned_tag() {
  IMG="$1" perl -ne 'if (/\Q$ENV{IMG}\E:([A-Za-z0-9._-]+)/) { print "$1\n"; exit }' "configurations/$2"
}
semver() { local t="${1#v}"; echo "${t%%-*}"; }

if [[ "${1:-}" == "--show" ]]; then
  echo "configuration: $old_config"
  while read -r image repo; do
    [[ -z "$image" || "$image" == \#* ]] && continue
    echo "  $image=$(pinned_tag "$image" "$old_config")   (releases: https://github.com/$repo/releases)"
  done < scripts/release-watch.conf
  exit 0
fi

if [[ $# -lt 2 ]]; then
  sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
new_config="$1"; shift
[[ "$new_config" =~ ^[A-Za-z0-9._-]+\.yml$ ]] || die "configuration name must look like <client>-<version>-<type>.yml"
[[ -z "$(git status --porcelain)" ]] || echo "warning: the working tree already has uncommitted changes" >&2

# Parse <image>=<tag> pairs and read the current pins before changing anything.
images=(); old_tags=(); new_tags=()
for arg in "$@"; do
  image="${arg%=*}"; tag="${arg##*=}"
  [[ "$image" != "$arg" && -n "$image" && "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || die "expected <image>=<tag>, got '$arg'"
  old="$(pinned_tag "$image" "$old_config")"
  [[ -n "$old" ]] || die "$image is not pinned in configurations/$old_config (see scripts/bump.sh --show)"
  images+=("$image"); old_tags+=("$old"); new_tags+=("$tag")
done

if [[ "$new_config" != "$old_config" ]]; then
  [[ ! -e "configurations/$new_config" ]] || die "configurations/$new_config already exists"
  git mv "configurations/$old_config" "configurations/$new_config"
fi

files=()
while IFS= read -r f; do
  case "$f" in LICENSE|scripts/*|.github/*) ;; *) files+=("$f") ;; esac
done < <(git ls-files)

# Replace OLD with NEW as a whole version token (so 1.15.1 never matches 11.15.1).
replace() {
  OLD="$1" NEW="$2" perl -pi -e 's/(?<![0-9.])\Q$ENV{OLD}\E(?![0-9])/$ENV{NEW}/g' "${files[@]}"
}
# Replace an exact string, no boundary rules.
replace_literal() {
  OLD="$1" NEW="$2" perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "${files[@]}"
}

[[ "$new_config" == "$old_config" ]] || replace "$old_config" "$new_config"

# 1. Image references, which are unambiguous.
for i in "${!images[@]}"; do
  replace_literal "${images[$i]}:${old_tags[$i]}" "${images[$i]}:${new_tags[$i]}"
done

# 2. Bare mentions of the old tag and version (package.json, README prose,
#    upstream doc links). Skip a version two images shared if they now move to
#    different releases, since its bare mentions could belong to either.
for i in "${!images[@]}"; do
  [[ "${old_tags[$i]}" == "${new_tags[$i]}" ]] && continue
  ambiguous=""
  for j in "${!images[@]}"; do
    if [[ $j -ne $i && "$(semver "${old_tags[$j]}")" == "$(semver "${old_tags[$i]}")" \
          && "$(semver "${new_tags[$j]}")" != "$(semver "${new_tags[$i]}")" ]]; then
      ambiguous=1
    fi
  done
  if [[ -n "$ambiguous" ]]; then
    echo "warning: bare mentions of $(semver "${old_tags[$i]}") left as they are; update them by hand" >&2
    continue
  fi
  replace "${old_tags[$i]}" "${new_tags[$i]}"
  old_v="$(semver "${old_tags[$i]}")"; new_v="$(semver "${new_tags[$i]}")"
  [[ "$old_v" == "$new_v" ]] || replace "$old_v" "$new_v"
done

echo
git status --short
echo
echo "Next: review 'git diff' (README prose may describe the old release),"
echo "run scripts/validate.sh, and test-deploy before shipping a major release."
