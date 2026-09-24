# native/ — the Rust core spike (task 07876c)

What this tests: dsync's core and CLI in Rust, with Flutter as a GUI-only
head over [rinf](https://pub.dev/packages/rinf). It lives beside the Dart
code (lib/dsync_core, lib/cli) and changes none of it.

Why: on the phone, peer:// over Dart TLS tops out at ~8 MiB/s and 84–133 ms
of CPU per MiB; a standalone rustls receiver ran at the full Wi-Fi link
(~30 MiB/s) on one connection at ~10–12 ms/MiB
(benchmark/rust_tls_probe, commit 448a510).

## Layout

One Cargo workspace (`native/Cargo.toml`, `native/Cargo.lock`):

| crate | path | what |
|---|---|---|
| `dsync-core` (lib `dsync_core`) | `core/` | identity, device ids, pinned mutual TLS, framing, server, client, metrics |
| `dsync-cli` (bin `dsync-rs`) | `cli/` | `id`, `serve`, `push` |
| `hub` | `hub/` | the rinf entry crate: signals and the task that runs the server |

The core, in brief:

- **Identity** (`identity.rs`): a self-signed ECDSA P-256 certificate from
  rcgen, end entity (`IsCa::ExplicitNoCa`; webpki refuses a CA-flagged
  leaf). Stored as `cert.pem` and `key.pem` (0600).
- **Device id** (`device_id.rs`): SHA-256 of the certificate's full
  SubjectPublicKeyInfo DER, as 16 colon-separated groups of 4 hex digits:
  the same idea as the Dart `deviceIdFromCertificateDer`, with no
  compatibility promised.
- **TLS** (`tls.rs`): rustls 0.23 on ring, TLS 1.3 only, and client auth
  required. One verifier (`PinnedPeer`) serves both directions: it admits
  the certificate whose device id the `PeerPin` admits (one id, or `ANY`),
  then checks the handshake signature against it. It never looks at a CA, a
  name or an expiry.
- **Framing** (`wire.rs`): 4-byte magic; then per file, a tag, a u16 path
  length, the `/` path, a u64 size, an i64+u32 mtime, and the bytes; then
  an end tag. The server answers once, with a summary (files and bytes),
  after the last file is on disk. There is no per-file ack, so it pipelines.
- **Server** (`server.rs`): accepts one connection. The socket is read on
  tokio through a 256 KiB `BufReader`. Each file goes whole to one of N
  blocking writer threads (`spawn_blocking`), round robin. Each thread
  creates parent dirs (cached), writes, and sets the mtime on the handle.
  Each queue is bounded (8 chunks), which is the back-pressure. Events:
  `Ready`, `Connected`, `FileDone` (one per file), and `Progress`, throttled
  to one per 50 ms (`throttle.rs`).
- **Client** (`client.rs`): walks the directory (regular files only), then a
  blocking reader thread frames headers and content into 256 KiB chunks.
  Chunks run across file boundaries, so small files batch. The async side
  writes the chunks to the TLS stream through a 256 KiB `BufWriter`.
- **Metrics** (`metrics.rs`, `cpu.rs`): bytes, files, wall time, MiB/s,
  files/s, and process CPU from `/proc/self/stat` utime+stime (Linux and
  Android), as seconds and ms per MiB. The server measures from the end of
  the handshake to the last file on disk. The client measures from the end
  of the handshake to the server's summary.

**Writer pool size:** the default is 4 (`--writers` on the CLI; the hub uses
the default). On the desktop, 1 and 4 writers are within noise: both trees
land in page cache in tens of ms, see below. The pool is there for the
phone: `/storage/emulated/0` is FUSE, where each create is a round trip. It
is the first knob to turn if small files are slow there.

## Build and run

Rust toolchain: stable 1.93 here, with rustup. Cargokit installs missing
Android targets itself.

```sh
# Core and CLI
cargo build --release --manifest-path native/Cargo.toml -p dsync-cli
native/target/release/dsync-rs id [--identity DIR]      # default $XDG_CONFIG_HOME/dsync-rs
native/target/release/dsync-rs serve --root DIR --port 47670 --allow <peer-id>|ANY [--writers 4] [--verbose]
native/target/release/dsync-rs push DIR --host H --port 47670 --pin <server-id>

# Gates
cargo test --manifest-path native/Cargo.toml
cargo clippy --manifest-path native/Cargo.toml --all-targets

# Regenerating the Dart side of the signals after editing hub/src/signals.rs.
# The rinf CLI runs from a checkout of rinf 8.10.1, not a global install:
cargo run --manifest-path <rinf>/rust_crate_cli/Cargo.toml -- gen
#  -> lib/app/rust/bindings (pubspec.yaml `rinf:` section); committed.

# The app: nothing extra. Cargokit builds native/hub as part of
flutter build linux --release
flutter build apk --release

# The rinf integration test (Linux shown; on the phone, -d <serial>)
flutter drive --profile -d linux --driver=test_driver/integration_test.dart \
  --target=integration_test/rust_spike_test.dart \
  [--dart-define=ROOT=<dir>] [--dart-define=PORT=47670] [--dart-define=ALLOW=<id>|ANY]
# once it prints `[rust-spike] ready port … id <id>`:
native/target/release/dsync-rs push <tree> --host <host> --port 47670 --pin <id>
```

## How the build is integrated

- rinf is a Flutter **FFI plugin**, not a Dart build hook. So `dart compile
  exe bin/dsync.dart` is unaffected: it still builds, and the Dart CLI never
  imports rinf. The plugin's platform code runs Cargokit on `native/hub`,
  with the path hard-coded to `<app>/native/hub`:
  - **Linux and Windows**: rinf's `linux/rust.cmake` calls
    `apply_cargokit(... ../native/hub hub)`. The `.so` is built in
    `build/linux/x64/<mode>/plugins/rinf/cargokit_build/`, not in
    `native/target`, and bundled as `bundle/lib/libhub.so`.
  - **Android**: rinf's `android/build.gradle` applies
    `cargokit/gradle/plugin.gradle`. That plugin adds a
    `cargokitCargoBuildHub<Variant>` task before
    `merge<Variant>NativeLibs`, with the NDK from `flutter.ndkVersion`. It
    builds one `cargo build --target` per Flutter target platform. For
    `flutter build apk --release` those are `android-arm`, `android-arm64`
    and `android-x64`, so the Rust targets are `armv7-linux-androideabi`,
    `aarch64-linux-android` and `x86_64-linux-android` (debug builds add
    `android-x86`). Cargokit ran `rustup target add` for the two that were
    missing here (armv7, x86_64). `--target-platform android-arm64` builds
    one.
  - **iOS and macOS**: podspecs build a `staticlib` through Cargokit. Not
    tried here.
- **The Cargo workspace sits at `native/Cargo.toml`, not at the repo root
  as rinf's template has it.** Cargokit builds by manifest path, so Cargo
  finds the workspace and `native/Cargo.lock` above the hub on its own.
- **rinf is vendored with a patch** (`third_party/rinf`, `PATCHED.md`,
  picked up through `dependency_overrides`). Cargokit's Gradle task calls
  `project.exec`, which Gradle 9 removed; this app is on Gradle 9.3.1 / AGP
  9.1.0, and pub rinf 8.10.1 (the latest) fails with "Could not find method
  exec()". The patch injects `ExecOperations`; nothing else changed.
  Upstream cargokit main has the same `project.exec` call.
- `lib/main.dart` awaits `initializeRust(assignRustSignal)` before the
  existing bootstrap. The hub only parks on its signal receivers until Dart
  sends `StartServe`. Integration tests don't run `main`, so
  `rust_spike_test.dart` calls `initializeRust` itself.
- The generated bindings import `meta` and `tuple`, so both are now pinned
  direct dependencies.

## APK size (release, fat APK: arm, arm64, x64)

| | bytes | |
|---|---|---|
| before (trunk 448a510) | 75,374,622 (75.4 MB) | |
| after | 81,289,640 (81.3 MB) | +5,915,018 (+7.8%) |
| `libhub.so` arm64-v8a | 2,162,032 | what a phone's split download pays |
| `libhub.so` armeabi-v7a | 1,290,556 | |
| `libhub.so` x86_64 | 2,423,552 | |

These use the default release profile: no LTO, `opt-level` 3, and AGP
strips the symbols. `lto = true` and `opt-level = "s"` are open levers.

## Local numbers (Linux, 24 cores, loopback, receive root on ext4 in page cache)

Trees from `benchmark/synthetic_tree.dart`: **large**, 25 files, 101.9 MiB
(the generator's mean came out at 4.1 MiB); **small**, 1,500 files × ~13
KiB, 30 per dir, 19.4 MiB. The runs repeat as listed.

| run | server (receive) | client (send) | Dart progress signals |
|---|---|---|---|
| CLI→CLI large, 4 writers ×4 | 1882–2407 MiB/s, 0.04–0.05 s, cpu 0.5–0.6 ms/MiB | 1859–2366 MiB/s | (CLI: 1 event) |
| CLI→CLI large, 1 writer | 2070 MiB/s, cpu 0.6 ms/MiB | 2051 MiB/s | (1) |
| CLI→CLI small, 4 writers ×4 | 724–842 MiB/s, 56–65 k files/s, cpu 1.5–2.1 ms/MiB | 712–830 MiB/s | (1) |
| CLI→CLI small, 1 writer ×4 | 557–790 MiB/s, 43–61 k files/s, cpu 1.5–2.1 ms/MiB | 547–780 MiB/s | (1) |
| CLI→app (rinf) large ×2 | 2382 / 2458 MiB/s, 0.04 s, cpu 0.5 / 0.7 ms/MiB | 2345 / 2426 MiB/s | 1 / 1 |
| CLI→app (rinf) small ×3 | 1427 / 1090 / 597 MiB/s, 110 k / 84 k / 46 k files/s, cpu 1.5 / 2.6 / 2.6 ms/MiB | 1370 / 1054 / 583 MiB/s | 1 / 1 / 1 |
| CLI→CLI 1 GiB (200 × 5 MiB) | 3139 MiB/s, 0.33 s, cpu 0.5 ms/MiB | 3133 MiB/s | (7 events) |
| CLI→app (rinf) 1 GiB | 3043 MiB/s, 0.34 s, cpu 0.6 ms/MiB | 3038 MiB/s | 7 |

On loopback both trees finish in 10–50 ms, so these prove the path works
end to end, not what it costs. The CPU reading has 10 ms resolution, and
one throttle interval (50 ms) is longer than a whole transfer. The 1 GiB
rows show the throttle at work: 7 signals in 0.34 s. The app's CPU is the
whole Flutter process, engine included. Every received tree was checked
byte for byte (`diff -r`) with its mtimes, down to the nanosecond. The phone
run is the one that answers the question.

## What was awkward

- **Gradle 9 vs Cargokit** (above): no released rinf builds an APK with
  this project's Android toolchain without the vendored patch.
- rinf's template assumes a root `Cargo.toml` and gitignores the generated
  bindings. Here the workspace stays in `native/` and the bindings are
  committed, so `flutter analyze` and a fresh checkout work without the
  rinf CLI.
- `rinf gen` copies Rust doc comments verbatim, so the Dart side reads
  `[allow_peer_id]`. The generated code turns `u64` into a `Uint64` wrapper
  class, not `int`.
- The rinf Android plugin still applies the Kotlin Gradle Plugin. Flutter
  warns that a future version will refuse it.
- A hot restart does not reload Rust; any Rust change needs a rebuild.
- `flutter test` (unit and widget tests) cannot load `libhub`, since only
  the platform build runs Cargokit. Anything that calls `initializeRust` is
  integration-test territory, and the Rust logic is tested with
  `cargo test`.
- Whenever it lacks a Rust target, Cargokit runs `rustup target add` from
  inside Gradle, which changes the machine's toolchain.

## SAF and iOS: how a file descriptor would reach the core

No code here, only the findings. The spike writes plain paths under the
All-files grant (`MANAGE_EXTERNAL_STORAGE`).

**LocalSend's approach** (`packages/localsend_isolates/lib/src/task/server/file_saver.dart`,
`packages/core/src/http/server/common/save.rs`,
`app/android/.../MainActivity.kt`):

1. Dart decides, per file, whether the destination is a SAF tree (a
   `content://` URI or an SD card). If it is, it calls a method channel.
   Kotlin runs `DocumentsContract.createDocument(parentUri, mime, name)`,
   then `contentResolver.openFileDescriptor(uri, "wt")`, then
   `ParcelFileDescriptor.detachFd()`. It returns `{uri, fd}`, an `int`
   whose ownership passes to the caller.
2. Dart hands the `int` to Rust (through flutter_rust_bridge there; here it
   would be an `i32` field in a rinf `DartSignal`). The Rust type is
   `FileUploadTarget::Fd { fd: RawFd, … }`, `#[cfg(target_os = "android")]`.
3. Rust wraps it with `unsafe { File::from_raw_fd(fd) }` (it now owns and
   closes it), writes, truncates, and applies the mtime through the
   descriptor (`File::set_times`). That works for SAF documents with no
   path. Timestamp failures are ignored, since some providers refuse them.
4. A retry reopens the document by URI for a fresh fd: the first one was
   consumed.

**What it would mean for dsync:**

- **Per-file cost.** Every file costs a Rust→Dart→Kotlin→Dart→Rust round
  trip, plus a `createDocument`, which is slow in the SAF provider
  (milliseconds). For 1,500 small files that is the bottleneck, not TLS.
  The server would need an "open these N targets" request carried by signal
  and answered in batches. Directories would need their own
  `createDocument` calls, and "set mtime" and "rename" are not
  first-class in SAF.
- **Alternative:** skip Dart and call `ContentResolver` from Rust over JNI
  (`jni` + `ndk-context`). rinf's Android side is a bare plugin with no
  JNI of its own, so a small Kotlin or JNI shim would have to hand over the
  `JavaVM` and a `Context`. That removes the Dart hop but not the
  provider's cost, and it puts Android API calls into the core.
- **Reads:** a reader side (push from the phone) would need the same thing,
  with `openFileDescriptor(uri, "r")` and a tree walk through
  `DocumentsContract.buildChildDocumentsUriUsingTree`. There is no
  `read_dir` on a content URI.
- **The All-files grant, as now,** keeps the core on plain `std::fs` paths,
  and it is what the spike ran under. SAF only matters if Play policy or
  SD-card roots force it.
- **iOS:** the app container is a plain path, so Rust `std::fs` just works.
  A user-picked folder outside the container is a security-scoped URL. The
  Swift or Dart side calls `startAccessingSecurityScopedResource()` (and
  keeps a bookmark for later launches); after that, the path is usable by
  the whole process, Rust included, until `stop…`. So on iOS the core
  receives a path, not an fd, and the head owns the grant's lifetime.

## Open questions for the full migration

1. **Identity on the app side.** The hub generates a fresh identity per app
   run (ServeReady carries its id). Where does the key live: the app
   support dir as now, or the Android Keystore / iOS Keychain? Who creates
   it, Rust or the head?
2. **Protocol.** This framing is a spike. The real one needs versioning,
   a scan and plan exchange, deletes and renames, resume, and integrity
   (hash per file or per chunk). Does the Rust core re-implement SPEC's
   protocol, or replace it (there are no users)?
3. **The durability contract.** No fsync, no temp-file-plus-rename, and a
   file is written in place. Whatever the Dart core's apply path guarantees
   (lib/dsync_core/apply) has to move over.
4. **The signal surface.** How big is the API between head and core
   (profiles, pairing, runs, conflicts)? Per-file events stay in Rust here;
   the UI gets throttled counts. Is rinf's one-way signal model enough, or
   is request/response wanted (flutter_rust_bridge)?
5. **Threading on the phone.** The hub runs a multi-thread tokio runtime
   (one worker per core, 8 on the OnePlus 6), plus writer threads. Should
   it be capped on big.LITTLE? Measure CPU ms/MiB with 2 workers against 8.
6. **Writer count on FUSE storage.** Is 4 right for `/storage/emulated/0`?
   The hub has no knob yet; the CLI has `--writers`.
7. **Gradle 9.** Upstream the Cargokit fix to rinf (or cargokit), or keep
   the vendored copy?
8. **The Dart CLI and `lib/dsync_core`.** Delete them at the switch, and do
   they keep existing tests' value as a spec (golden vectors for ids,
   formats)?
9. **Size and build time.** 2.1 MiB of arm64 `.so` today. LTO and
   `opt-level="s"` untried. A clean APK build now compiles Rust for three
   ABIs.
10. **Desktop and iOS.** Windows and macOS are untested beyond what the
    rinf plugin claims; iOS is a staticlib through CocoaPods.
