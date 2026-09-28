# Releasing dsync

How to cut a release, written for a maintainer who has not done it in a year.
Most of this file is about the Android release key, the one thing that cannot
be recovered if lost.

## Artifacts

`scripts/release.sh` builds everything the machine it runs on can build and
collects it, with versioned names and a `SHA256SUMS`, in `dist/X.Y.Z/`:

| Host | Default targets | Artifacts |
|---|---|---|
| Linux | `android linux cli` | `dsync-X.Y.Z-android.apk`, `.aab`, `dsync-X.Y.Z-linux-<arch>.tar.gz`, `dsync-cli-X.Y.Z-linux-<arch>.tar.gz` |
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

1. **Pass the gates** on the release commit: `dart analyze`, `flutter test`,
   and in `native/` `cargo fmt --check`, `cargo clippy --workspace
   --all-targets -- -D warnings`, `cargo test --workspace`.
2. **Run the phone release check** on a test device — README, "Release check on
   a phone". It needs a phone and a person to plug it in, so no CI runs it; it
   is the gate before every release.
3. **Bump the version** in `pubspec.yaml`: `version: X.Y.Z+N`. `N` is Android's
   versionCode and must be higher than every published release's, or the
   update will not install. Commit it (`chore: version X.Y.Z`).
4. **Build and verify** on each host (Linux, then macOS and Windows for their
   desktop apps and CLIs):

   ```sh
   scripts/release.sh
   ```

   Its `android` target runs `scripts/release-android.sh`, which builds `build/app/outputs/flutter-apk/app-release.apk` and
   `build/app/outputs/bundle/release/app-release.aab`, checks each has exactly
   one signer and that it is the release key (`apksigner verify
   --print-certs` for the APK, `keytool -printcert -jarfile` for the AAB), and
   prints both paths with their SHA-256.
5. **Tag and publish**, with every host's artifacts gathered in `dist/X.Y.Z/`:

   ```sh
   git tag vX.Y.Z
   git push origin vX.Y.Z
   gh release create vX.Y.Z dist/X.Y.Z/*
   ```

## CI

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs on every
`v*` tag: it decodes the keystore into `$RUNNER_TEMP`, runs
`scripts/release-android.sh`, deletes the keystore and uploads the APK and AAB
as run artifacts. It needs three repository secrets:

- `ANDROID_KEYSTORE_BASE64` — `base64 -w0 ~/.config/dsync/release.jks`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_PASSWORD`

```sh
base64 -w0 ~/.config/dsync/release.jks | gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEYSTORE_PASSWORD
gh secret set ANDROID_KEY_PASSWORD
```

**The workflow is untested**: it was written before the repository had a
remote. Expect to fix it on its first run, and check the artifact's
fingerprint by hand that time (`apksigner verify --print-certs`).

## Testing the release script without the real key

Generate a throwaway keystore with alias `dsync` somewhere outside the repo,
point the three environment variables at it, and run the script with
`DSYNC_EXPECTED_CERT_SHA256` set to the throwaway certificate's SHA-256. Without
that override the script must fail, naming the fingerprint mismatch. Delete the
throwaway keystore afterwards.
