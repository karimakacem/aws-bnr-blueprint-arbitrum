#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Compare each pinned client image with the latest GitHub release of the
# project that publishes it (listed in scripts/release-watch.conf). When the
# pin is behind, open one issue per new release in this repository.
#
# Usage: scripts/check-release.sh            # needs GH_TOKEN with issues:write
#        DRY_RUN=1 scripts/check-release.sh  # only print what it finds
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

configs=(configurations/*.yml)
if [[ ${#configs[@]} -ne 1 || ! -f "${configs[0]}" ]]; then
  echo "expected exactly one file in configurations/" >&2
  exit 1
fi
config="${configs[0]}"

# Tag pinned for <image> in the configuration file, e.g. v3.12.1-70fa99a.
pinned_tag() {
  IMG="$1" perl -ne 'if (/\Q$ENV{IMG}\E:([A-Za-z0-9._-]+)/) { print "$1\n"; exit }' "$config"
}
# Release number without a leading "v" or a "-<suffix>": v3.12.1-70fa99a -> 3.12.1
semver() { local t="${1#v}"; echo "${t%%-*}"; }

seen=" "
while read -r image repo <&3; do
  [[ -z "$image" || "$image" == \#* ]] && continue
  pinned="$(pinned_tag "$image")"
  if [[ -z "$pinned" ]]; then
    echo "error: $image is not pinned in $config" >&2
    exit 1
  fi
  latest="$(gh api "repos/$repo/releases/latest" --jq .tag_name)"
  newest="$(printf '%s\n%s\n' "$(semver "$pinned")" "$(semver "$latest")" | sort -V | tail -1)"
  if [[ "$newest" == "$(semver "$pinned")" ]]; then
    echo "up to date: $image:$pinned (latest $repo release: $latest)"
    continue
  fi
  echo "behind: $image:$pinned, latest $repo release is $latest"

  # One issue per upstream release, even when several images come from it.
  title="Release watch: $repo $latest is available"
  [[ "$seen" == *" $title "* ]] && continue
  seen="$seen$title "
  if [[ -n "${DRY_RUN:-}" ]]; then
    echo "  (dry run) would open issue: $title"
    continue
  fi
  existing="$(gh issue list --state all --search "\"$title\" in:title" --json title --jq ".[] | select(.title == \"$title\") | .title")"
  if [[ -n "$existing" ]]; then
    echo "  issue already exists: $title"
    continue
  fi
  read -r -d '' body <<EOF || true
This blueprint pins \`$image:$pinned\`. [$repo $latest](https://github.com/$repo/releases/tag/$latest) is now the latest release.

Before bumping, read the release notes and the chain operator's upgrade notices. Some releases are required before a network upgrade; others are optional.

To bump, from a clone of this repository:

\`\`\`bash
scripts/bump.sh --show                                   # current pins
scripts/bump.sh <new-config-file> <image>=<new-tag> ...  # rename + repin
scripts/validate.sh                                      # tests + cdk synth
\`\`\`

Use the exact image tag the release publishes (Nitro tags carry a commit suffix, for example \`v3.12.1-70fa99a\`). Close this issue if you decide to skip the release; it will not be reopened.
EOF
  gh issue create --title "$title" --body "$body"
done 3< scripts/release-watch.conf
