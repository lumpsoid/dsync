# dsync-scan-probe

A developer tool, never shipped: what scanning one tree costs on this device,
split into the platform's floor and dsync's own code (core's `ScanProbe`),
and whether the tree's filesystem folds case (core's `probe_case_folding`).
It is a workspace member outside `default-members`, so a plain `cargo build`
in `native/` skips it and nothing in the app or the `dsync` CLI links it.

A profile syncs several entries; run the probe over each entry's local root
you care about, with the profile's ignore patterns.

```
dsync-scan-probe ROOT [--passes N] [--jobs N] [--ignore PATTERN]...
```

`--passes` (default 2) walks back to back: a later pass much faster than the
first says the cost is I/O and page cache. `--jobs` defaults to a run's.

## Desktop

```sh
cd native
cargo run --release -p dsync-scan-probe -- ~/some/tree --ignore .git
```

## Android, over adb

Cross-compile with the NDK (as `benchmark/device/run_backup_probe.sh` does),
push to `/data/local/tmp`, and run it there. The shell user can read shared
storage, so no app or grant is involved.

```sh
cd native
ndk_bin=$(echo /opt/android-ndk/toolchains/llvm/prebuilt/*/bin)
CC_aarch64_linux_android=$ndk_bin/aarch64-linux-android30-clang \
AR_aarch64_linux_android=$ndk_bin/llvm-ar \
CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$ndk_bin/aarch64-linux-android30-clang \
  cargo build --release -p dsync-scan-probe --target aarch64-linux-android
adb push target/aarch64-linux-android/release/dsync-scan-probe /data/local/tmp/
adb shell /data/local/tmp/dsync-scan-probe /storage/emulated/0/Documents
adb shell rm /data/local/tmp/dsync-scan-probe
```

The case-folding check creates and removes one dotfile in ROOT, so ROOT must
be writable for it to answer `Folds`; an unwritable root answers `Distinct`.
