#!/usr/bin/env bash
# dsync's version lives in pubspec.yaml (`X.Y.Z+N`, N being Android's
# versionCode) and in each shipped crate's Cargo.toml. This keeps them in step.
#
#   scripts/version.sh show           # print X.Y.Z+N
#   scripts/version.sh check          # fail unless every crate says X.Y.Z
#   scripts/version.sh bump X.Y.Z     # set every file to X.Y.Z, N += 1, date
#                                     # the changelog's [Unreleased] section
#
# `bump` also refreshes native/Cargo.lock for the workspace crates; it needs
# GNU sed (Linux). Commit the result as `chore(release): X.Y.Z`, then run
# scripts/tag-release.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly CRATES=(native/domain native/core native/cli native/hub native/version)

die() {
  echo "version: $*" >&2
  exit 1
}

pubspec_full() {
  sed -n 's/^version: //p' pubspec.yaml
}

crate_version() {
  sed -n '0,/^version = /s/^version = "\(.*\)"/\1/p' "$1/Cargo.toml"
}

check() {
  local full version crate bad=false
  full=$(pubspec_full)
  [[ "$full" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]] ||
    die "pubspec.yaml's version '$full' is not X.Y.Z+N."
  version=${full%+*}
  for crate in "${CRATES[@]}"; do
    if [[ "$(crate_version "$crate")" != "$version" ]]; then
      echo "version: $crate/Cargo.toml says $(crate_version "$crate"), pubspec.yaml $version." >&2
      bad=true
    fi
  done
  $bad && exit 1
  echo "version: $full, every crate agrees."
}

bump() {
  local next=$1 full build crate today
  [[ "$next" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$next' is not X.Y.Z."
  full=$(pubspec_full)
  build=${full#*+}
  [[ "$build" =~ ^[0-9]+$ ]] || die "pubspec.yaml's version '$full' has no +N."
  grep -q "^## \[$next\]" CHANGELOG.md && die "CHANGELOG.md already has a [$next] section."
  grep -q '^## \[Unreleased\]' CHANGELOG.md || die "CHANGELOG.md has no [Unreleased] section."

  sed -i "s/^version: .*/version: $next+$((build + 1))/" pubspec.yaml
  for crate in "${CRATES[@]}"; do
    sed -i "0,/^version = /s/^version = \".*\"/version = \"$next\"/" "$crate/Cargo.toml"
  done
  today=$(date +%Y-%m-%d)
  sed -i "s/^## \[Unreleased\]$/## [Unreleased]\n\n## [$next] - $today/" CHANGELOG.md

  (cd native && cargo update --workspace --quiet)
  check
}

case "${1:-}" in
  show) pubspec_full ;;
  check) check ;;
  bump) [[ $# == 2 ]] || die "usage: scripts/version.sh bump X.Y.Z"; bump "$2" ;;
  *) die "usage: scripts/version.sh show|check|bump X.Y.Z" ;;
esac
