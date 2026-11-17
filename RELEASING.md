# Releasing dsync

How to cut a release, written for a maintainer who has not done it in a year.
Most of this file is about the Android release key, the one thing that cannot
be recovered if lost.

## Artifacts

`scripts/release.sh` builds everything the machine it runs on can build and
collects it, with versioned names and a `SHA256SUMS`, in `dist/X.Y.Z/`:

| Host | Default targets | Artifacts |
|---|---|---|
| Linux | `android linux cli`, plus `cli-linux-arm64` on x86_64 | `dsync-X.Y.Z-android.apk`, `.aab`, `dsync-X.Y.Z-linux-<arch>.tar.gz`, `dsync-cli-X.Y.Z-linux-<arch>.tar.gz`, `dsync-cli-X.Y.Z-linux-arm64.tar.gz` (static, for a Raspberry Pi on a 64-bit OS) |
| macOS | `macos cli` | `dsync-X.Y.Z-macos.zip` (unsigned, not notarized), `dsync-cli-X.Y.Z-macos-<arch>.tar.gz` |
| Windows (Git Bash) | `windows cli` | `dsync-X.Y.Z-windows-<arch>.zip`, `dsync-cli-X.Y.Z-windows-<arch>.zip` |

Name targets to build only those (`scripts/release.sh cli linux`). It refuses
a dirty working tree; `--allow-dirty` builds anyway, for trying the pipeline
out, and such artifacts are never published. To gather one release from
several machines, copy each machine's files into one `dist/X.Y.Z/` and rerun
any target there: `SHA256SUMS` is rewritten over every file in the directory.

## The key, and why it matters

Android installs an update only if it is signed by the same key as the
installed app. Every dsync release must be signed by the **dsync release
key**, forever:

- keystore: `~/.config/dsync/release.jks` on the maintainer's machine
- alias `dsync`, RSA, SHA384withRSA, created 2026-09-26
- certificate SHA-256: the `RELEASE_CERT_SHA256` constant in
  [`scripts/release-android.sh`](scripts/release-android.sh), the one place it
  is written down. The script refuses any build whose certificate differs.
- passwords (store and key): the password manager entry
  **`dsync/android-release-key`**. Never write them anywhere else in the repo.
- app id: `io.github.lumpsoid.dsync`. It can never change either: a different
  id is a different app.

**Keep two backups** of the keystore (for example the password manager entry's
attachment and an offline drive), as base64 so they survive being pasted:

```sh
base64 -w0 ~/.config/dsync/release.jks > release.jks.b64
```

dsync is distributed outside Google Play, so there is no Play App Signing to
fall back on: **a lost key, or a lost password, means existing installs can
never be updated.** Users would have to uninstall (losing the app's data) and
install a new app.

### Restoring the key from a backup

```sh
mkdir -p ~/.config/dsync
base64 -d release.jks.b64 > ~/.config/dsync/release.jks
chmod 600 ~/.config/dsync/release.jks
keytool -list -v -keystore ~/.config/dsync/release.jks -alias dsync
```

`keytool` asks for the store password; the `SHA256:` line it prints must equal
`RELEASE_CERT_SHA256`.

## Telling the build where the key is

Locally: copy [`android/key.properties.example`](android/key.properties.example)
to `android/key.properties` and fill in the absolute keystore path and both
passwords. That file is gitignored; never commit it.

On CI, or instead of the file: `ANDROID_KEYSTORE_PATH`,
`ANDROID_KEYSTORE_PASSWORD` and `ANDROID_KEY_PASSWORD`. These win over the
file.

Without either, `flutter build apk --release` still works but signs with the
debug key, so everyday development never needs the release key. Such an APK
must never be published; `scripts/release-android.sh` refuses to run without a
key.

## Cutting a release

1. **Run the phone release check** on a test device
   ([docs/development.md](docs/development.md), "Release check on a phone").
   It needs a phone and a person to plug it in, so no CI runs it; it is the
   gate before every release.
2. **Write the notes**: everything users will notice is under
   `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md).
3. **Bump the version** on trunk:

   ```sh
   scripts/version.sh bump X.Y.Z
   git commit -am 'chore(release): X.Y.Z'
   ```

   It sets `pubspec.yaml` to `X.Y.Z+N` with `N` one higher (Android's
   versionCode, which must grow or the update will not install), sets the
   five shipped crates to `X.Y.Z`, refreshes `native/Cargo.lock` and turns
   `[Unreleased]` into `[X.Y.Z] - <today>`. `dsync --version` and the app's
   Settings page show `X.Y.Z (<commit>)` (`native/version/build.rs`).
4. **Tag**:

   ```sh
   scripts/tag-release.sh
   git push origin trunk vX.Y.Z
   ```

   It refuses a dirty tree, a branch other than trunk and disagreeing
   versions, runs `scripts/check.sh`, and makes an annotated `vX.Y.Z` whose
   message is the changelog section.
5. **CI publishes it.** The release workflow (below) builds every platform
   and creates the GitHub release. Check the APK's certificate once it is up:
   `apksigner verify --print-certs dsync-X.Y.Z-android.apk` must print
   `RELEASE_CERT_SHA256`.

To build locally instead, or to try the pipeline, `scripts/release.sh` builds
everything this host can into `dist/X.Y.Z/` (see "Artifacts" above);
`--allow-dirty` builds from uncommitted changes, and such artifacts are never
published.

## CI

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs on every
`vX.Y.Z` tag. It fails unless the tag matches `pubspec.yaml`; builds Android
(signed, through `scripts/release-android.sh`), the Linux app with both Linux
CLIs, and the macOS and Windows apps with their CLIs, each through
`scripts/release.sh`; then writes one `SHA256SUMS` over all of them and
publishes the GitHub release with the tag's annotation as its notes.

It needs three repository secrets, and fails without them rather than
publish a debug-signed APK:

- `ANDROID_KEYSTORE_BASE64`: `base64 -w0 ~/.config/dsync/release.jks`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_PASSWORD`

```sh
base64 -w0 ~/.config/dsync/release.jks | gh secret set ANDROID_KEYSTORE_BASE64 -R lumpsoid/dsync
gh secret set ANDROID_KEYSTORE_PASSWORD -R lumpsoid/dsync
gh secret set ANDROID_KEY_PASSWORD -R lumpsoid/dsync
```

**The workflow has not run yet.** Expect to fix it on its first tag (the Linux
build packages, the macOS and Windows runners), and check the APK's
fingerprint by hand that time.

## Testing the release script without the real key

Generate a throwaway keystore with alias `dsync` somewhere outside the repo,
point the three environment variables at it, and run the script with
`DSYNC_EXPECTED_CERT_SHA256` set to the throwaway certificate's SHA-256. Without
that override the script must fail, naming the fingerprint mismatch. Delete the
throwaway keystore afterwards.

## Maintaining

The other jobs, in the order they come up.

**Fresh checkout.** Install rustup and Flutter 3.47.9, then `flutter pub get`
and `scripts/check.sh`. For release builds, restore the key (above) and write
`android/key.properties`. Install the commit hook that strips agent
attribution with `agent-kit-repo-hooks` if you use it.

**Everyday.** Branch from trunk, keep `scripts/check.sh` green, merge. A
change users will notice adds a line under `[Unreleased]` in the changelog.

**Dependency updates.** Dependabot opens weekly pull requests for cargo, pub,
Gradle and GitHub Actions, minor and patch grouped. Some things move together
and Dependabot cannot see it:

- **rinf**: the Dart package (`pubspec.yaml`, `rinf: 8.10.1`), the vendored
  copy in `third_party/rinf` that `dependency_overrides` points at, the crate
  in `native/hub/Cargo.toml` (`rinf = "=8.10.1"`), and the `rinf` CLI that
  regenerates `lib/app/rust/bindings/`. Re-vendor and re-apply the patch in
  `third_party/rinf/PATCHED.md`, or drop the override once rinf ships the fix.
- **Flutter**: `FLUTTER_VERSION` in both workflows, and the `sdk:` pin in
  `pubspec.yaml`, which must be the Dart SDK that Flutter release bundles.
- **Gradle, AGP and Kotlin** follow the Flutter release's requirements, not
  their own latest.

**One-time GitHub settings.** Repository description and topics; Settings →
Code security: Dependabot alerts and security updates on; the three signing
secrets; optionally a branch protection rule on trunk requiring the `test`
workflow's checks.

