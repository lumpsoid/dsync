#!/usr/bin/env bash
# Tags the release pubspec.yaml names, after every gate passes. From the repo
# root, on trunk, after `scripts/version.sh bump X.Y.Z` is committed:
#
#   scripts/tag-release.sh
#
# The annotated tag vX.Y.Z carries the changelog's [X.Y.Z] section; the
# release workflow publishes it as the GitHub release notes. Nothing is
# pushed: the script prints the command.
set -euo pipefail

die() {
  echo "tag-release: $*" >&2
  exit 1
}

cd "$(dirname "$0")/.."

[[ "$(git symbolic-ref --short HEAD)" == trunk ]] || die "not on trunk."
[[ -z "$(git status --porcelain)" ]] || die "the working tree has uncommitted changes."
scripts/version.sh check

full=$(scripts/version.sh show)
version=${full%+*}
tag=v$version
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "$tag already exists."

# The section's body: every line after its heading up to the next `## [`.
notes=$(awk -v head="## [$version]" '
  index($0, head) == 1 { found = 1; next }
  found && /^## \[/ { exit }
  found { print }
' CHANGELOG.md | sed '/./,$!d')
[[ -n "$notes" ]] || die "CHANGELOG.md has no [$version] section, or it is empty. Run scripts/version.sh bump $version."

scripts/check.sh

# --cleanup=verbatim: the default strips `### Added` as a comment line.
printf 'dsync %s\n\n%s\n' "$version" "$notes" | git tag -a --cleanup=verbatim -F - "$tag"

echo
echo "tag-release: tagged $tag at $(git rev-parse --short HEAD). Publish with:"
echo "  git push origin trunk $tag"
