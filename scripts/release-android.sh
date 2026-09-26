#!/usr/bin/env bash
# Builds the signed Android release APK and AAB and proves both carry the
# dsync release key. From the repo root:
#
#   scripts/release-android.sh
#
# The key comes from android/key.properties or, on CI, from
# ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD and ANDROID_KEY_PASSWORD
# (alias `dsync`); RELEASING.md says where each lives. Without one the script
# refuses: a plain `flutter build apk --release` would quietly sign with the
# debug key, and an APK signed with any other key can never update an
# installed dsync.
#
# After the build, `apksigner verify --print-certs` (the APK) and `keytool
# -printcert -jarfile` (the AAB, which apksigner does not read) must each
# report exactly one signer whose certificate SHA-256 is RELEASE_CERT_SHA256
# below. Only to test this script with a throwaway key,
# DSYNC_EXPECTED_CERT_SHA256 overrides it.
set -euo pipefail

# The certificate SHA-256 of the dsync release key (alias `dsync`, RSA,
# created 2026-09-26). Every release ever published must carry it.
readonly RELEASE_CERT_SHA256=62:DC:20:1B:63:6E:07:3C:ED:AA:FB:21:26:3B:60:B5:EE:D7:B2:7A:A8:A7:29:9D:24:80:CD:18:CA:6D:8B:97

readonly APK=build/app/outputs/flutter-apk/app-release.apk
readonly AAB=build/app/outputs/bundle/release/app-release.aab

die() {
  echo "release-android: $*" >&2
  exit 1
}

# Fails unless $2 (one digest per line, any case, colons or not) is exactly
# one signer, the expected one. $1 names the artifact.
check_signer() {
  local digests signers
  digests=$(printf '%s\n' "$2" | tr -d ':' | tr '[:upper:]' '[:lower:]')
  signers=$(printf '%s\n' "$digests" | grep -c . || true)
  [[ "$signers" == 1 ]] || die "$1 has $signers signers, expected exactly one."
  [[ "$digests" == "$expected" ]] ||
    die "$1 is signed by certificate SHA-256 $digests, not the dsync release key $expected. Wrong keystore? See RELEASING.md."
}

cd "$(dirname "$0")/.."

# The key: env vars first (as Gradle reads them), else android/key.properties.
if [[ -n "${ANDROID_KEYSTORE_PATH:-}" ]]; then
  [[ -f "$ANDROID_KEYSTORE_PATH" ]] ||
    die "ANDROID_KEYSTORE_PATH=$ANDROID_KEYSTORE_PATH is not a file. See RELEASING.md."
  [[ -n "${ANDROID_KEYSTORE_PASSWORD:-}" && -n "${ANDROID_KEY_PASSWORD:-}" ]] ||
    die "ANDROID_KEYSTORE_PATH is set but ANDROID_KEYSTORE_PASSWORD or ANDROID_KEY_PASSWORD is not. See RELEASING.md."
elif [[ ! -f android/key.properties ]]; then
  die "no release key: neither android/key.properties nor ANDROID_KEYSTORE_PATH. Refusing to build a release signed with the debug key. See RELEASING.md."
fi

# apksigner ships in the SDK's build-tools, not on PATH: the newest one under
# ANDROID_HOME, ANDROID_SDK_ROOT or android/local.properties' sdk.dir.
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
if [[ -z "$sdk" && -f android/local.properties ]]; then
  sdk=$(sed -n 's/^sdk\.dir=//p' android/local.properties)
fi
[[ -n "$sdk" ]] || die "no Android SDK: set ANDROID_HOME or run flutter once to write android/local.properties."
apksigner=$(find "$sdk/build-tools" -mindepth 2 -maxdepth 2 -name apksigner 2>/dev/null | sort -V | tail -n 1)
[[ -n "$apksigner" ]] || die "no apksigner under $sdk/build-tools. Install Android SDK build-tools."

command -v keytool >/dev/null || die "no keytool on PATH. Install a JDK."

expected=${DSYNC_EXPECTED_CERT_SHA256:-$RELEASE_CERT_SHA256}
expected=$(printf '%s' "$expected" | tr -d ':' | tr '[:upper:]' '[:lower:]')

flutter build apk --release
flutter build appbundle --release

certs=$("$apksigner" verify --print-certs "$APK") || die "apksigner rejects $APK."
check_signer "$APK" "$(printf '%s\n' "$certs" | sed -n 's/^Signer #[0-9]* certificate SHA-256 digest: //p')"

certs=$(keytool -printcert -jarfile "$AAB") || die "keytool cannot read the signature of $AAB."
check_signer "$AAB" "$(printf '%s\n' "$certs" | sed -n 's/^[[:space:]]*SHA256: //p')"

version=$(sed -n 's/^version: //p' pubspec.yaml)
echo
echo "release-android: dsync $version, signed by the release key ($expected)."
for artifact in "$APK" "$AAB"; do
  echo "  $PWD/$artifact"
  echo "    sha256 $(sha256sum "$artifact" | cut -d ' ' -f 1)"
done
