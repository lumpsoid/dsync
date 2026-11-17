# Developing dsync

How the repository is laid out, how to build and test it, and the checks
before a release. User-facing docs are in the [README](../README.md); the
behaviour is specified in [SPEC.md](../SPEC.md).

## Components

v0, in development. The core engine, the CLI and the Flutter head are
implemented; the head pairs either way round — by pasting the payload line or
scanning the QR beside it, or by showing its own code for the other device to
scan or paste (SPEC §4.4).

The Flutter head also runs on Linux, macOS and Windows, where it manages the
device rather than syncing from a phone: it reads and writes the *same* state
directory the CLI does (SPEC §3, §8.3), so this device's identity and
certificate, each pairing's certificate and name, and which replica roots each
paired device may reach are all editable from the app and enforced by
`dsync agent`. It can also serve a replica of its own: **Answer paired
devices** binds the same listener `dsync agent --serve` binds, so another
device can start a run *against* this one — for as long as that page is open,
never in the background (SPEC §4.4, §16). The other socket it binds is the
enrolment endpoint behind **Show this device's code**, open only while that
page is.

| Area | State |
|---|---|
| `native/domain/` (`dsync-domain`) — pure rules and values: parsing, reconcile, plan, spread, exit policy, profiles, tuning | implemented |
| `native/core/` (`dsync-core`) — I/O: stores, the `Replica` trait, the protocol, transports, pairing, `Run` | implemented |
| `native/cli/` (`dsync-cli`, binary `dsync`) — sync, status, agent, pair, archive | implemented |
| `native/hub/` — the rinf bridge the Flutter head loads | implemented |
| `native/version/` (`dsync-version`) — this build's version, read from `pubspec.yaml` | implemented |
| `lib/app/` — Flutter head: profiles home, devices, device, this device, pair, pair show, serve, run setup, run | implemented |

## Build and run

Prerequisites: a Rust toolchain via [rustup](https://rustup.rs) (`native/` has no
pinned toolchain file, so `stable` is what CI builds against too — see
`.github/workflows/test.yml`'s `dtolnay/rust-toolchain@stable`), and Flutter
3.47.9, the release bundling the Dart SDK `pubspec.yaml` pins, for the `app`
head.

Build and install the CLI:

```sh
cd native && cargo build --release -p dsync-cli   # native/target/release/dsync
# or: cargo install --path native/cli
```

Run the app:

```sh
flutter run -d linux
flutter build linux            # or: flutter build apk --release
```

Cargokit builds the Rust `hub` crate as part of either command; on Android it
additionally needs the NDK, and Cargokit may run `rustup target add` itself as
a side effect of the Gradle build — see SPEC §13 for that and the other
build-integration gotchas.

State — this device's identity, the paired-device store, archive logs — lives
under the platform state directory (SPEC §8.3); `--state-dir` overrides it for
the CLI. A remote host reached over `ssh://` needs a `dsync` binary on its
PATH, or `--remote-dsync <path>` naming where it is.

## Layout

The engine and the CLI are a Rust cargo workspace under `native/`; the Flutter
head lives at `lib/app/` and talks to the workspace through one seam (SPEC
§13):

```
native/
  domain/   dsync-domain — pure rules and values: parsing, reconcile, plan,
            spread, exit policy, profiles, tuning
  core/     dsync-core — I/O: stores, the Replica trait, the protocol,
            transports, pairing, Run
  cli/      dsync-cli — the `dsync` binary: sync, status, agent, pair, archive
  hub/      the rinf bridge: intent-named commands in, one reply per command,
            and each session (run, serve, pairing window) out as whole-view
            snapshots, over dsync-core
  version/  dsync-version — this build's version for the CLI and the hub:
            pubspec.yaml's X.Y.Z and the commit it was built from
  scan_probe/  dsync-scan-probe — developer tool, not shipped: what scanning
            a tree costs on this device (desktop or over adb; its README)
lib/app/
  core_link/   CoreChannel (the one interface: rinf's signals) and the
               concrete CoreLink over it — the only place rinf is imported
               in lib/app/
  (everything else: pages, view state, controllers, scopes)
```

`dsync-domain` depends on nothing but a few pure crates — no `tokio`, no
filesystem I/O, no network — so its reconcile, plan and exit-code rules are
plain functions over values, testable with no mock and no temp directory. See
SPEC §13 for the full dependency rule between the crates and how Cargokit
builds `native/hub` as part of a Flutter build.

## Development

Rust (`native/`):

```sh
cd native && cargo fmt --check && cargo clippy --workspace --all-targets -- -D warnings \
  && cargo build --workspace --all-targets && cargo test --workspace
```

The head:

```sh
flutter pub get
dart analyze
flutter test
```

For a fast loop on one head file, `flutter test test/app/<file>.dart`.

After editing `native/hub/src/signals.rs`, the Dart bindings under
`lib/app/rust/bindings/` need regenerating and committing — see SPEC §13 for
the `rinf gen` invocation.

One more test crosses the seam for real and is not part of `flutter test`:
`integration_test/head_pairs_and_syncs_with_cli_test.dart` builds the real
`dsync-cli` binary and drives the app against it over `flutter drive`. Its
own header has the exact invocation; in outline:

```sh
(cd native && cargo build -p dsync-cli)
work=$(mktemp -d)
XDG_STATE_HOME=$work/state XDG_CONFIG_HOME=$work/config \
flutter drive --profile -d linux \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/head_pairs_and_syncs_with_cli_test.dart \
  --dart-define=DSYNC=$PWD/native/target/debug/dsync \
  --dart-define=WORK=$work
```

`scripts/check.sh` runs all of the above in CI's order.

### Releasing

[RELEASING.md](../RELEASING.md) is the whole procedure: the Android release key
and its backups, `scripts/release-android.sh`, the CI release workflow, and the
phone release check below as the gate before every release.

### Release check on a phone

Before a release, run the app on an Android **test device** against this
desktop's `dsync`. Everything is driven from here, by one command, and nobody
touches the phone: nothing opens the folder chooser or Settings on it, and the
script asks nothing.

```sh
adb devices   # the serial
integration_test/phone_release_check.sh --device <serial> --i-understand-this-reinstalls
```

**It wipes the app on that phone.** It uninstalls `io.github.lumpsoid.dsync`
(the archives, identity, pairings and All-files grant go with it), installs a test
build and leaves it installed with All-files access granted, and deletes and
recreates `/storage/emulated/0/dsync-e2e`. It refuses to run without both
flags; `--dry-run` prints the plan and touches nothing. Reinstall your own
build afterwards.

It checks, and ends with PASS or FAIL for each: (a) All-files access, with the
`MANAGE_EXTERNAL_STORAGE` app-op set over adb to `default` (the folder
refused, and Run setup asking for the grant) and then `allow` (the same app
process takes it); (b) Run setup taking the picked folder's path; (c) a sync
the app starts against `dsync agent --serve`, and one the desktop CLI starts
against the app's Serve page; (d) the app force-stopped mid-apply, relaunched,
its unfinished-run marker seen and the run recovered. It does **not** cover
the system folder chooser, the conversion of its `content://` answer to a
path, or a person granting access in Settings: those need a person. The phone
must be awake, unlocked and kept so (Developer options → Stay awake), on the
same Wi-Fi, and this desktop must accept inbound TCP on port 28791. The
script's header has the details; the desktop's side of it lives under
`~/.cache/dsync/scratch/e2e-<time>/`.

### Android permissions

**Android release builds reach the network.** `android/app/src/main/AndroidManifest.xml`
declares the `INTERNET` permission — Flutter provides it only to the `debug`
and `profile` source sets, so its absence there made every connect work under
`flutter run` and fail in a release build. The `CAMERA` permission the Pair
page's scanner reads through is declared there too, and `NSCameraUsageDescription`
is the iOS half of the same pair (SPEC §4.4).
