#!/usr/bin/env bash
# Builds dsync's release artifacts on this machine and collects them, with
# versioned names, in dist/<version>/. From the repo root:
#
#   scripts/release.sh                  # everything this host builds
#   scripts/release.sh cli linux        # just these targets
#   scripts/release.sh --allow-dirty    # build from uncommitted changes
#
# Targets, and the default set per host:
#
#   android   signed APK + AAB, via scripts/release-android.sh     (Linux)
#   linux     the Flutter bundle, as a .tar.gz                     (Linux)
#   macos     dsync.app, as a .zip (unsigned, not notarized)       (macOS)
#   windows   the Flutter runner folder, as a .zip                 (Windows)
#   cli       the `dsync` binary + LICENSE, .tar.gz (.zip on Windows) (all)
#
# Each machine adds its own files to the same dist/<version>/; copy the other
# machines' artifacts in and rerun (any target) to refresh SHA256SUMS over
# all of them. On Windows, run it from Git Bash.
#
# The version is pubspec.yaml's X.Y.Z (the +N build number is Android's
# alone). A dirty working tree is refused: an artifact must be reproducible
# from a commit.
set -euo pipefail

die() {
  echo "release: $*" >&2
  exit 1
}

cd "$(dirname "$0")/.."

allow_dirty=false
targets=()
for arg in "$@"; do
  case "$arg" in
    --allow-dirty) allow_dirty=true ;;
    android | linux | macos | windows | cli) targets+=("$arg") ;;
    *) die "unknown argument '$arg'. Targets: android linux macos windows cli; flag: --allow-dirty." ;;
  esac
done

case "$(uname -s)" in
  Linux) host=linux ;;
  Darwin) host=macos ;;
  MINGW* | MSYS* | CYGWIN*) host=windows ;;
  *) die "unsupported host $(uname -s)." ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 flutter_arch=x64 ;;
  aarch64 | arm64) arch=arm64 flutter_arch=arm64 ;;
  *) die "unsupported architecture $(uname -m)." ;;
esac

if [[ ${#targets[@]} == 0 ]]; then
  case "$host" in
    linux) targets=(android linux cli) ;;
    macos) targets=(macos cli) ;;
    windows) targets=(windows cli) ;;
  esac
fi

if [[ -n "$(git status --porcelain)" ]]; then
  $allow_dirty || die "the working tree has uncommitted changes. Commit them, or pass --allow-dirty for a build that is not a release."
  echo "release: building from a dirty tree; these artifacts are not a release." >&2
fi

version=$(sed -n 's/^version: \([^+]*\).*/\1/p' pubspec.yaml)
[[ -n "$version" ]] || die "no version in pubspec.yaml."
dist=$PWD/dist/$version
mkdir -p "$dist"

# Packs directory $2's contents into archive $1 (.tar.gz or .zip), under a
# top-level folder named after the archive.
pack() {
  local out=$1 src=$2 name stage
  name=$(basename "$out")
  name=${name%.tar.gz}
  name=${name%.zip}
  stage=$(mktemp -d)
  cp -R "$src" "$stage/$name"
  rm -f "$out"
  case "$out" in
    *.tar.gz) tar -C "$stage" -czf "$out" "$name" ;;
    *.zip)
      if [[ "$host" == windows ]]; then
        powershell.exe -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$stage/$name")' -DestinationPath '$(cygpath -w "$out")'"
      else
        (cd "$stage" && zip -qr "$out" "$name")
      fi
      ;;
  esac
  rm -rf "$stage"
}

build_android() {
  scripts/release-android.sh
  cp build/app/outputs/flutter-apk/app-release.apk "$dist/dsync-$version-android.apk"
  cp build/app/outputs/bundle/release/app-release.aab "$dist/dsync-$version-android.aab"
}

build_linux() {
  flutter build linux --release
  pack "$dist/dsync-$version-linux-$arch.tar.gz" "build/linux/$flutter_arch/release/bundle"
}

build_macos() {
  flutter build macos --release
  rm -f "$dist/dsync-$version-macos.zip"
  ditto -c -k --sequesterRsrc --keepParent build/macos/Build/Products/Release/dsync.app \
    "$dist/dsync-$version-macos.zip"
}

build_windows() {
  flutter build windows --release
  pack "$dist/dsync-$version-windows-$arch.zip" "build/windows/$flutter_arch/runner/Release"
}

build_cli() {
  (cd native && cargo build --release -p dsync-cli)
  local exe=dsync ext=.tar.gz stage
  [[ "$host" == windows ]] && exe=dsync.exe ext=.zip
  stage=$(mktemp -d)
  cp "native/target/release/$exe" LICENSE "$stage/"
  pack "$dist/dsync-cli-$version-$host-$arch$ext" "$stage"
  rm -rf "$stage"
}

for target in "${targets[@]}"; do
  echo "release: building $target"
  "build_$target"
done

(
  cd "$dist"
  rm -f SHA256SUMS
  shasum -a 256 -- * > SHA256SUMS
)

echo
echo "release: dsync $version ($(git rev-parse --short HEAD)) in $dist"
cat "$dist/SHA256SUMS"
